//! Local hardening for the SpotFast integration. No root service or network listener.
use std::fs::{DirBuilder, File, OpenOptions};
use std::io::{self, BufRead, Read};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path};

pub const MAX_FRAME: usize = 4096;
pub const MAX_RESULTS: usize = 100;
pub const MAX_CONNECTIONS: usize = 8;
pub const MAX_INDEX_BYTES: u64 = 2 * 1024 * 1024 * 1024;

pub fn launcher_mode() -> bool { std::env::var_os("SPOTFAST_NAMES_ONLY").is_some() }

fn denied(reason: &str) -> io::Error { io::Error::new(io::ErrorKind::PermissionDenied, reason) }

/// Only root/current-user ancestors, no symlinks, no foreign-writable ancestors.
pub fn private_dir(path: &Path) -> io::Result<()> {
    if !path.is_absolute() { return Err(denied("data directory must be absolute")); }
    let uid = unsafe { libc::geteuid() };
    let mut current = std::path::PathBuf::new();
    for part in path.components() {
        match part {
            Component::RootDir | Component::Normal(_) => current.push(part.as_os_str()),
            _ => return Err(denied("non-normal data directory")),
        }
        let m = match std::fs::symlink_metadata(&current) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                DirBuilder::new().mode(0o700).create(&current)?;
                std::fs::symlink_metadata(&current)?
            }
            Err(e) => return Err(e),
        };
        if !m.is_dir() || (m.uid() != uid && m.uid() != 0) || m.mode() & 0o022 != 0 {
            return Err(denied("unsafe data-directory ancestor"));
        }
    }
    let m = std::fs::symlink_metadata(path)?;
    if m.uid() != uid { return Err(denied("data directory belongs to another user")); }
    let f = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC).open(path)?;
    f.set_permissions(std::fs::Permissions::from_mode(0o700))
}

pub fn private_file(path: &Path, truncate: bool) -> io::Result<File> {
    let file = OpenOptions::new().read(true).write(true).create(true).mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path)?;
    let m = file.metadata()?;
    if !m.is_file() || m.uid() != unsafe { libc::geteuid() } || m.nlink() != 1 {
        return Err(denied("unsafe private file"));
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    if truncate { file.set_len(0)?; }
    Ok(file)
}

/// Copies disk bytes into an anonymous map. Disk truncation cannot invalidate pointers.
pub fn snapshot(path: &Path) -> io::Result<memmap2::Mmap> {
    let mut f = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path)?;
    let m = f.metadata()?;
    if !m.is_file() || m.uid() != unsafe { libc::geteuid() } || m.nlink() != 1 || m.mode() & 0o077 != 0 {
        return Err(denied("index must be a private same-user regular file"));
    }
    let len = m.len();
    if len < crate::index::HDR as u64 || len > MAX_INDEX_BYTES { return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid index length")); }
    let mut map = memmap2::MmapMut::map_anon(len as usize)?;
    f.read_exact(&mut map)?;
    map.make_read_only()
}

/// Bounded frame allocation, including when the peer never sends a newline.
pub fn frame(reader: &mut impl BufRead) -> io::Result<Option<String>> {
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return if bytes.is_empty() { Ok(None) } else { Err(io::Error::new(io::ErrorKind::UnexpectedEof, "unterminated frame")) };
        }
        let newline = available.iter().position(|&b| b == b'\n');
        let count = newline.map_or(available.len(), |i| i + 1);
        if bytes.len() + count > MAX_FRAME { return Err(io::Error::new(io::ErrorKind::InvalidData, "request too large")); }
        bytes.extend_from_slice(&available[..count]);
        reader.consume(count);
        if newline.is_some() {
            bytes.pop();
            return String::from_utf8(bytes).map(Some).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid UTF-8"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    #[test]
    fn frames_are_bounded_and_complete() {
        assert_eq!(frame(&mut Cursor::new(b"hello\n")).unwrap(), Some("hello".into()));
        assert!(frame(&mut Cursor::new(vec![b'x'; MAX_FRAME + 1])).is_err());
        assert!(frame(&mut Cursor::new(b"partial")).is_err());
        assert!(frame(&mut Cursor::new(b"\xff\n")).is_err());
        assert!(frame(&mut Cursor::new(b"")).unwrap().is_none());
    }
    #[test]
    fn private_file_rejects_symlinks_and_hardlinks() {
        let base = std::env::temp_dir().join(format!("spotfast-file-test-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        let target = base.join("target");
        std::fs::write(&target, b"preserve").unwrap();
        let link = base.join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(private_file(&link, true).is_err());
        std::fs::remove_file(&link).unwrap();
        std::fs::hard_link(&target, &link).unwrap();
        assert!(private_file(&link, true).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"preserve");
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn disk_truncation_cannot_invalidate_snapshot() {
        use std::io::Write;
        let path = std::env::temp_dir().join(format!("spotfast-snapshot-test-{}", std::process::id()));
        let mut file = private_file(&path, true).unwrap();
        let mut bytes = vec![0u8; crate::index::HDR];
        bytes[..4].copy_from_slice(b"test");
        file.write_all(&bytes).unwrap();
        let map = snapshot(&path).unwrap();
        file.set_len(0).unwrap();
        assert_eq!(&map[..4], b"test");
        std::fs::remove_file(path).unwrap();
    }
}
