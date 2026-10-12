#!/usr/bin/env python3
import unittest
from verify_runtime import registration_is_live

class RuntimeTests(unittest.TestCase):
    def test_live_shortcut_matches_the_current_running_job(self):
        self.assertTrue(registration_is_live({'pid':123,'registered':True,'commandSpace':True}, '\tstate = running\n\tpid = 123\n'))
    def test_clean_exit_cannot_pass_with_a_stale_registration_file(self):
        self.assertFalse(registration_is_live({'pid':123,'registered':True,'commandSpace':True}, '\tstate = not running\n\tlast exit code = 0\n'))
    def test_restarted_or_unregistered_process_cannot_pass(self):
        for registration in [{'pid':122,'registered':True,'commandSpace':True}, {'pid':123,'registered':False,'commandSpace':True}]:
            self.assertFalse(registration_is_live(registration, '\tstate = running\n\tpid = 123\n'))

if __name__ == '__main__': unittest.main()
