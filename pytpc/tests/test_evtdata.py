import unittest
import pytpc
import numpy as np
import numpy.testing as nptest

class TestEvent(unittest.TestCase):
    """Tests for the event class."""

    def setUp(self):
        self.evt = pytpc.Event()
        e = self.evt  # for my sanity
        e.traces = np.zeros((10), e.dt)

    def test_hits_dims(self):
        """Tests the dimension of hits output"""
        hits = self.evt.hits()
        self.assertEqual(len(hits), 10240)

    def test_hits(self):
        """Tests that hits calculates the hits right."""
        e = self.evt
        e.traces = np.zeros((100), e.dt)
        for i, tr in enumerate(e.traces):
            e.traces[i]['pad'] = i * 2
            e.traces[i]['data'][:] = np.full(512, 1.0)
        hits = e.hits()
        exp = np.zeros(10240)
        for i in e.traces['pad']:
            exp[i] = 512
        nptest.assert_equal(hits, exp)


class TestCalibration(unittest.TestCase):
    """Tests for calibrate_z and uncalibrate_z"""

    def setUp(self):
        self.data = np.arange(512)
        self.clock = 10
        self.vd = 5

    def test_calibrate(self):
        cal = pytpc.evtdata.calibrate_z(self.data, self.vd, self.clock)
        exp = self.data * self.vd / self.clock * 10
        nptest.assert_allclose(cal, exp)

    def test_uncalibrate(self):
        uncal = pytpc.evtdata.uncalibrate_z(self.data, self.vd, self.clock)
        exp = self.data / self.vd * self.clock / 10
        nptest.assert_allclose(uncal, exp)

    def test_inversion(self):
        """Make sure the process is reversible"""
        cal = pytpc.evtdata.calibrate_z(self.data, self.vd, self.clock)
        uncal = pytpc.evtdata.uncalibrate_z(cal, self.vd, self.clock)
        nptest.assert_allclose(self.data, uncal)