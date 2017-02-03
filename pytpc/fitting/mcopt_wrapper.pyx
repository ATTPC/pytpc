cimport mcopt
from libcpp.vector cimport vector as cppvec
from libcpp.map cimport map as cppmap
from libcpp.pair cimport pair as cpppair
cimport armadillo as arma
import numpy as np
cimport numpy as np
from cython.operator cimport dereference as deref, preincrement as preinc
from libc.stdio cimport printf
from ..utilities import find_vertex_energy


cdef cppvec[double] np2cppvec(np.ndarray[np.double_t, ndim=1] v):
    cdef cppvec[double] res
    cdef double[:] vView = v
    for i in range(v.shape[0]):
        res.push_back(v[i])
    return res


cdef class Gas:
    """Gas(eloss, enVsZ)

    Container for gas data in the C++ code.

    Parameters
    ----------
    eloss : ndarray
        Energy loss data in MeV/m, as a function of projectile energy.
        This should be indexed in 1-keV steps.
    enVsZ : ndarray
        Projectile total kinetic energy, in MeV, as a function of position, in mm.
        Index is in 1-mm steps from 0 to 1000 mm. The projectile should start at 1000 mm.
    """
    def __cinit__(self, np.ndarray[np.double_t, ndim=1] eloss, np.ndarray[np.double_t, ndim=1] enVsZ):
        cdef cppvec[double] elossVec = np2cppvec(eloss)
        cdef cppvec[double] enVsZVec = np2cppvec(enVsZ)

        self.thisptr = new mcopt.Gas(elossVec, enVsZVec)

    def __dealloc__(self):
        del self.thisptr


cdef class Tracker:
    """Tracker(mass_num, charge_num, gas, efield, bfield)

    A class for simulating the track of a charged particle in the AT-TPC.

    Parameters
    ----------
    mass_num, charge_num : int
        The mass and charge number of the tracked particle.
    beam_enu0 : float
        The initial energy per nucleon of the beam projectile.
    beam_mass, beam_charge : int
        The mass and charge numbers of the beam projectile.
    pygas : pytpc gas class
        The detector gas.
    efield, bfield : ndarray
        The electric and magnetic fields in SI units.
    max_en : int, optional
        The maximum allowable particle energy in MeV. This is used to make the energy lookup
        table for the tracker.

    Raises
    ------
    ValueError
        If the dimensions of an input array were invalid.
    """
    def __cinit__(self, int massNum, int chargeNum, double beam_enu0, int beam_mass, int beam_charge, pygas,
                  np.ndarray[np.double_t, ndim=1] efield, np.ndarray[np.double_t, ndim=1] bfield,
                  int max_en=100):

        ens = np.arange(0, max_en*1000, dtype='int')
        eloss = pygas.energy_loss(ens / 1000, massNum, chargeNum)

        zs = np.arange(0, 1000, dtype='int')
        en_vs_z = find_vertex_energy(zs / 1000., beam_enu0, beam_mass, beam_charge, pygas)

        self.gas = Gas(eloss, en_vs_z)

        cdef arma.vec *efieldVec
        cdef arma.vec *bfieldVec
        try:
            efieldVec = arma.np2vec(efield)
            bfieldVec = arma.np2vec(bfield)
            self.thisptr = new mcopt.Tracker(massNum, chargeNum, self.gas.thisptr, deref(efieldVec), deref(bfieldVec))
        finally:
            del efieldVec, bfieldVec

    def __dealloc__(self):
        del self.thisptr

    @property
    def mass_num(self):
        """The mass number of the tracked particle."""
        return self.thisptr.getMassNum()

    @property
    def charge_num(self):
        """The charge number of the tracked particle."""
        return self.thisptr.getChargeNum()

    @property
    def efield(self):
        """The electric field in the detector, in V/m."""
        cdef arma.vec efieldVec = self.thisptr.getEfield()
        return arma.vec2np(efieldVec)

    @efield.setter
    def efield(self, np.ndarray[np.double_t, ndim=1] value):
        if len(value) != 3:
            raise ValueError('E field vector must have dimension 3')

        cdef arma.vec *efieldVec
        try:
            efieldVec = arma.np2vec(value)
            self.thisptr.setEfield(deref(efieldVec))
        finally:
            del efieldVec

    @property
    def bfield(self):
        """The magnetic field in the detector, in Tesla."""
        cdef arma.vec bfieldVec = self.thisptr.getBfield()
        return arma.vec2np(bfieldVec)

    @bfield.setter
    def bfield(self, np.ndarray[np.double_t, ndim=1] value):
        if len(value) != 3:
            raise ValueError('B field vector must have dimension 3')

        cdef arma.vec *bfieldVec
        try:
            bfieldVec = arma.np2vec(value)
            self.thisptr.setBfield(deref(bfieldVec))
        finally:
            del bfieldVec

    def track_particle(self, double x0, double y0, double z0, double enu0, double azi0, double pol0):
        """Tracker.track_particle(x0, y0, z0, enu0, azi0, pol0)

        Simulate the trajectory of a particle.

        Parameters
        ----------
        x0, y0, z0, enu0, azi0, pol0 : float
            The initial position (m), energy per nucleon (MeV/u), and azimuthal and polar angles (rad).

        Returns
        -------
        ndarray
            The simulated track. The columns are x, y, z, time, energy/nucleon, azimuthal angle, polar angle.
            The positions are in meters, the time is in seconds, and the energy is in MeV/u.

        Raises
        ------
        RuntimeError
            If tracking fails for some reason.
        """
        cdef mcopt.Track tr = self.thisptr.trackParticle(x0, y0, z0, enu0, azi0, pol0)
        cdef arma.mat trmat = tr.getMatrix()
        return arma.mat2np(trmat)


cdef class PadPlane:
    """A lookup table for finding the number of the pad under a certain (x, y) position.

    Parameters
    ----------
    lookup_table : ndarray
        An array of pad number as a function of x (columns) and y (rows).
    x_lower_bound : float
        The x value of the first column of the lookup table.
    x_delta : float
        The x step between adjacent columns.
    y_lower_bound : float
        The y value of the first row of the lookup table.
    y_delta : float
        The y step between adjacent rows.
    rot_angle : float, optional
        An angle, in radians, through which to rotate the pad plane.
    """
    def __cinit__(self, np.ndarray[np.uint16_t, ndim=2] lut, double xLB, double xDelta,
                  double yLB, double yDelta, double rotAngle=0):
        cdef arma.Mat[mcopt.pad_t] *lutMat
        try:
            lutMat = arma.np2uint16mat(lut)
            self.thisptr = new mcopt.PadPlane(deref(lutMat), xLB, xDelta, yLB, yDelta, rotAngle)
        finally:
            del lutMat

    def __dealloc__(self):
        del self.thisptr

    def get_pad_number_from_coordinates(self, double x, double y):
        """Look up the pad number under the given point.

        Parameters
        ----------
        x, y : float
            The x and y position to look up.

        Returns
        -------
        int
            The pad number under the given point. This will be whatever value is in the lookup table at that position.
            If the lookup table contains invalid values (e.g. to represent areas that do not contain a pad), then
            the result should be compared to the invalid value to check that it is a valid pad number.

        Raises
        ------
        RuntimeError
            If the point was outside the dimension of the lookup table, or if anything else failed.
        """
        return self.thisptr.getPadNumberFromCoordinates(x, y)

    @staticmethod
    def generate_pad_coordinates(double rotation_angle):
        cdef cppvec[cppvec[cppvec[double]]] v = mcopt.PadPlane.generatePadCoordinates(rotation_angle)
        cdef size_t dim0 = v.size()
        cdef size_t dim1 = v[0].size()
        cdef size_t dim2 = v[0][0].size()
        cdef np.ndarray[np.double_t, ndim=3] a = np.empty((dim0, dim1, dim2), dtype=np.double)

        for i in range(dim0):
            for j in range(dim1):
                for k in range(dim2):
                    a[i, j, k] = v[i][j][k]

        return a


cdef class EventGenerator:
    """A GET event generator. This can be used to generate events from simulated tracks.

    Parameters
    ----------
    pad_plane : PadPlane instance
        The pad lookup table to use when projecting to the Micromegas. The units should be meters.
    vd : array-like
        The drift velocity vector, in cm/us.
    clock : float
        The write clock, in MHz.
    shape : float
        The shaping time, in seconds.
    mass_num : int
        The particle's mass number.
    ioniz : float
        The mean ionization potential of the gas, in eV.
    micromegas_gain : double
        The gain in the micromegas.
    electronics_gain : double
        The gain of the electronics (the value of the capacitor on the amplifier).
    tilt : double
        The tilt angle, in radians.
    diff_sigma : double
        The size of the lateral straggling distribution.
    """
    def __cinit__(self, PadPlane pads, np.ndarray[np.double_t, ndim=1] vd, double clock, double shape,
                  unsigned massNum, double ioniz, double micromegas_gain, double electronics_gain, double tilt, double diff_sigma):
        self.pyPadPlane = pads
        cdef arma.vec *vdVec
        try:
            vdVec = arma.np2vec(vd)
            self.thisptr = new mcopt.EventGenerator(self.pyPadPlane.thisptr, deref(vdVec), clock * 1e6, shape, massNum,
                                                    ioniz, micromegas_gain, electronics_gain, tilt, diff_sigma)
        finally:
            del vdVec

    def __dealloc__(self):
        del self.thisptr

    @property
    def mass_num(self):
        """The mass number of the tracked particle."""
        return self.thisptr.massNum
    @mass_num.setter
    def mass_num(self, int newval):
        self.thisptr.massNum = newval

    @property
    def ioniz(self):
        """The ionization potential of the gas, in eV."""
        return self.thisptr.ioniz
    @ioniz.setter
    def ioniz(self, double newval):
        self.thisptr.ioniz = newval

    @property
    def micromegas_gain(self):
        """The micromegas gain."""
        return self.thisptr.micromegasGain
    @micromegas_gain.setter
    def micromegas_gain(self, double newval):
        self.thisptr.micromegasGain = newval

    @property
    def electronics_gain(self):
        return self.thisptr.electronicsGain

    @electronics_gain.setter
    def electronics_gain(self, newval):
        self.thisptr.electronicsGain = newval

    @property
    def tilt(self):
        """The detector tilt angle, in radians."""
        return self.thisptr.tilt
    @tilt.setter
    def tilt(self, double newval):
        self.thisptr.tilt = newval

    @property
    def clock(self):
        """The CoBo write clock frequency, in MHz."""
        return self.thisptr.clock * 1e-6
    @clock.setter
    def clock(self, double newval):
         self.thisptr.clock = newval * 1e6

    @property
    def shape(self):
        """The shaping time in the electronics, in seconds."""
        return self.thisptr.shape

    @shape.setter
    def shape(self, double newval):
        self.thisptr.shape = newval

    @property
    def vd(self):
        """The 3D drift velocity vector, in cm/µs."""
        return arma.vec2np(self.thisptr.vd)

    @vd.setter
    def vd(self, np.ndarray[np.double_t, ndim=1] newval):
        if len(newval) != 3:
            raise ValueError('Dimension of vd must be 3.')

        cdef arma.vec *vdVec
        try:
            vdVec = arma.np2vec(newval)
            self.thisptr.vd = deref(vdVec)
        finally:
            del vdVec

    def make_event(self, np.ndarray[np.double_t, ndim=2] pos, np.ndarray[np.double_t, ndim=1] en):
        """Make the electronics signals from the given track matrix.

        Parameters
        ----------
        pos : ndarray
            The simulated track positions, as (x, y, z) triples. The units should be compatible with the
            pad plane's units (probably meters).
        en : ndarray
            The energy of the simulated particle at each time step, in MeV/u.

        Returns
        -------
        dict
            A dict mapping the pad number (as int) to a generated signal (as an ndarray).

        Raises
        ------
        RuntimeError
            If the process fails for some reason.
        """
        cdef arma.mat *posMat
        cdef arma.vec *enVec
        cdef cppmap[mcopt.pad_t, arma.vec] evtmap
        res = {}

        try:
            posMat = arma.np2mat(pos)
            enVec = arma.np2vec(en)
            evtmap = self.thisptr.makeEvent(deref(posMat), deref(enVec))
        finally:
            del posMat, enVec

        cdef cppmap[mcopt.pad_t, arma.vec].iterator iter = evtmap.begin()

        while iter != evtmap.end():
            res[deref(iter).first] = arma.vec2np(deref(iter).second)
            preinc(iter)

        return res

    def make_peaks(self, np.ndarray[np.double_t, ndim=2] pos, np.ndarray[np.double_t, ndim=1] en):
        """Make the peaks table (x, y, time_bucket, amplitude, pad_number) from the simulated data.

        Parameters
        ----------
        pos : ndarray
            The simulated (x, y, z) positions. This should be in the same units as the pad plane, which
            is probably in meters.
        en : ndarray
            The simulated energies, in MeV/u.

        Returns
        -------
        ndarray
            The peaks, as described above.
        """
        cdef arma.mat *posMat
        cdef arma.vec *enVec
        cdef arma.mat peaks
        cdef np.ndarray[np.double_t, ndim=2] res
        try:
            posMat = arma.np2mat(pos)
            enVec = arma.np2vec(en)
            peaks = self.thisptr.makePeaksTableFromSimulation(deref(posMat), deref(enVec))
            res = arma.mat2np(peaks)
        finally:
            del posMat, enVec

        return res

    def make_mesh_signal(self, np.ndarray[np.double_t, ndim=2] pos, np.ndarray[np.double_t, ndim=1] en):
        """Make the simulated mesh signal, or the total across time buckets of the simulated signals.

        Parameters
        ----------
        pos : ndarray
            The simulated track positions, as (x, y, z) triples. The units should be compatible with the
            pad plane's units (probably meters).
        en : ndarray
            The energy of the simulated particle at each time step, in MeV/u.

        Returns
        -------
        ndarray
            The simulated mesh signal. The shape is (512,).
        """
        cdef arma.mat *posMat
        cdef arma.vec *enVec
        cdef arma.vec mesh
        cdef np.ndarray[np.double_t, ndim=1] res
        try:
            posMat = arma.np2mat(pos)
            enVec = arma.np2vec(en)
            mesh = self.thisptr.makeMeshSignal(deref(posMat), deref(enVec))
            res = arma.vec2np(mesh)
        finally:
            del posMat, enVec

        return res

    def make_hit_pattern(self, np.ndarray[np.double_t, ndim=2] pos, np.ndarray[np.double_t, ndim=1] en):
        """Make the simulated hit pattern from an event.

        This integrates the signal recorded on each pad and returns an array of the result for each pad.

        Parameters
        ----------
        pos : ndarray
            The simulated track positions, as (x, y, z) triples. The units should be compatible with the
            pad plane's units (probably meters).
        en : ndarray
            The energy of the simulated particle at each time step, in MeV/u.

        Returns
        -------
        ndarray
            The hit pattern, indexed by pad number.
        """
        cdef arma.mat *posMat
        cdef arma.vec *enVec
        cdef arma.vec mesh
        cdef np.ndarray[np.double_t, ndim=1] res
        try:
            posMat = arma.np2mat(pos)
            enVec = arma.np2vec(en)
            mesh = self.thisptr.makeHitPattern(deref(posMat), deref(enVec))
            res = arma.vec2np(mesh)
        finally:
            del posMat, enVec

        return res


cdef class Minimizer:
    """A Monte Carlo minimizer for particle tracks

    Parameters
    ----------
    tracker : mcopt.Tracker
        The tracker to use to simulate the tracks.
    evtgen : mcopt.EventGenerator
        The event generator to use to do the projection onto the pad plane.
    """
    def __cinit__(self, Tracker tr, EventGenerator evtgen, unsigned numIters, unsigned numPts, double redFactor):
        self.pyTracker = tr
        self.pyEvtGen = evtgen
        self.thisptr = new mcopt.MCminimizer(self.pyTracker.thisptr, self.pyEvtGen.thisptr,
                                             numIters, numPts, redFactor)

    def __dealloc__(self):
        del self.thisptr

    def minimize(self, np.ndarray[np.double_t, ndim=1] ctr0, np.ndarray[np.double_t, ndim=1] sigma0,
                 np.ndarray[np.double_t, ndim=2] expPos, np.ndarray[np.double_t, ndim=1] expHits,
                 double beam_xslope, double beam_xint, double beam_yslope, double beam_yint, bint details=False):
        """Perform chi^2 minimization for the track.

        Parameters
        ----------
        ctr0 : ndarray
            The initial guess for the track's parameters. These are (x0, y0, z0, enu0, azi0, pol0, bmag0).
        sig0 : ndarray
            The initial width of the parameter space in each dimension. The distribution will be centered on `ctr0` with a
            width of `sig0 / 2` in each direction.
        trueValues : ndarray
            The experimental data points, as (x, y, z) triples.
        numIters : int
            The number of iterations to perform before stopping. Each iteration draws `numPts` samples and picks the best one.
        numPts : int
            The number of samples to draw in each iteration. The tracking function will be evaluated `numPts * numIters` times.
        redFactor : float
            The factor to multiply the width of the parameter space by on each iteration. Should be <= 1.
        details : bool
            Controls the amount of detail returned. If true, return the things listed below. If False, return just
            the center and the last chi^2 value.

        Returns
        -------
        ctr : ndarray
            The fitted track parameters.
        minChis : ndarray
            The minimum chi^2 values at the end of each iteration. Each column corresponds to one chi^2 variable. Columns are
            (position chi2, hit pattern chi2, vertex position chi2).
        allParams : ndarray
            The parameters from all generated tracks. There will be `numIters * numPts` rows.
        goodParamIdx : ndarray
            The row numbers in `allParams` corresponding to the best points from each iteration, i.e. the ones whose
            chi^2 values are in `minChis`.

        Raises
        ------
        RuntimeError
            If tracking fails for some reason.
        """
        cdef arma.vec *ctr0Arr
        cdef arma.vec *sigma0Arr
        cdef arma.vec *expHitsArr
        cdef arma.mat *expPosArr
        cdef mcopt.MCminimizeResult minres
        cdef mcopt.BeamLocationEstimator* beamloc

        if len(ctr0) != len(sigma0):
            raise ValueError("Length of ctr0 and sigma0 arrays must be equal")

        try:
            ctr0Arr = arma.np2vec(ctr0)
            sigma0Arr = arma.np2vec(sigma0)
            expPosArr = arma.np2mat(expPos)
            expHitsArr = arma.np2vec(expHits)
            beamloc = new mcopt.BeamLocationEstimator(beam_xslope, beam_xint, beam_yslope, beam_yint)
            minres = self.thisptr.minimize(deref(ctr0Arr), deref(sigma0Arr), deref(expPosArr), deref(expHitsArr),
                                           deref(beamloc))
        finally:
            del ctr0Arr, sigma0Arr, expPosArr, expHitsArr

        cdef np.ndarray[np.double_t, ndim=1] ctr = arma.vec2np(minres.ctr)

        cdef np.ndarray[np.double_t, ndim=2] allParams
        cdef np.ndarray[np.double_t, ndim=2] minChis
        cdef np.ndarray[np.double_t, ndim=1] goodParamIdx

        cdef double lastPosChi
        cdef double lastEnChi

        if details:
            allParams = arma.mat2np(minres.allParams)
            minChis = arma.mat2np(minres.minChis)
            goodParamIdx = arma.vec2np(minres.goodParamIdx)
            return ctr, minChis, allParams, goodParamIdx

        else:
            lastPosChi = minres.minChis(minres.minChis.n_rows - 1, 0)
            lastEnChi = minres.minChis(minres.minChis.n_rows - 1, 1)
            return ctr, lastPosChi, lastEnChi

    def find_position_deviations(self, np.ndarray[np.double_t, ndim=2] simArr, np.ndarray[np.double_t, ndim=2] expArr):
        """Find the deviations in position between two tracks.

        Parameters
        ----------
        simArr : ndarray
            The simulated track.
        expArr : ndarray
            The experimental data.

        Returns
        -------
        devArr : ndarray
            The array of differences (or deviations).
        """
        cdef arma.mat *simMat
        cdef arma.mat *expMat
        cdef arma.mat devMat
        cdef np.ndarray[np.double_t, ndim=2] devArr

        try:
            simMat = arma.np2mat(simArr)
            expMat = arma.np2mat(expArr)
            devMat = self.thisptr.findPositionDeviations(deref(simMat), deref(expMat))
            devArr = arma.mat2np(devMat)

        finally:
            del simMat, expMat

        return devArr

    def find_hit_pattern_deviation(self, np.ndarray[np.double_t, ndim=2] simPos, np.ndarray[np.double_t, ndim=1] simEn,
                                   np.ndarray[np.double_t, ndim=1] expHits):
        """Find the deviations between the simulated track's hit pattern and the experimental hit pattern.

        Parameters
        ----------
        simPos : ndarray
            The simulated track's (x, y, z) positions. The units should be compatible with the
            units of the pad plane object (probably meters).
        simEn : ndarray
            The simulated track's energy values, in MeV/u. This should have the same number of rows
            as sim_pos.
        expHits : ndarray
            The simulated track's hit pattern, indexed by pad number.

        Returns
        -------
        ndarray
            The deviation between the two hit patterns, as seen by the minimizer.
        """
        cdef arma.mat *simPosMat
        cdef arma.vec *simEnVec
        cdef arma.vec *expHitsVec
        cdef arma.vec hitsDevVec
        cdef np.ndarray[np.double_t, ndim=1] hitsDev

        try:
            simPosMat = arma.np2mat(simPos)
            simEnVec = arma.np2vec(simEn)
            expHitsVec = arma.np2vec(expHits)

            hitsDevVec = self.thisptr.findHitPatternDeviation(deref(simPosMat), deref(simEnVec), deref(expHitsVec))
            hitsDev = arma.vec2np(hitsDevVec)

        finally:
            del simPosMat, simEnVec, expHitsVec

        return hitsDev

    def run_track(self, np.ndarray[np.double_t, ndim=1] params, np.ndarray[np.double_t, ndim=2] expPos,
                  np.ndarray[np.double_t, ndim=1] expHits):
        cdef arma.vec *paramsVec
        cdef arma.mat *expPosMat
        cdef arma.vec *expHitsVec

        cdef mcopt.Chi2Set chiset

        try:
            paramsVec = arma.np2vec(params)
            expPosMat = arma.np2mat(expPos)
            expHitsVec = arma.np2vec(expHits)

            chiset = self.thisptr.runTrack(deref(paramsVec), deref(expPosMat), deref(expHitsVec))

        finally:
            del paramsVec, expPosMat, expHitsVec

        return chiset.posChi2, chiset.enChi2

    def run_tracks(self, np.ndarray[np.double_t, ndim=2] params, np.ndarray[np.double_t, ndim=2] expPos,
                   np.ndarray[np.double_t, ndim=1] expHits):
        cdef arma.mat *paramsMat
        cdef arma.mat *expPosMat
        cdef arma.vec *expHitsVec

        cdef arma.mat chiMat
        cdef np.ndarray[np.double_t, ndim=2] chiArr

        try:
            paramsMat = arma.np2mat(params)
            expPosMat = arma.np2mat(expPos)
            expHitsVec = arma.np2vec(expHits)

            chiMat = self.thisptr.runTracks(deref(paramsMat), deref(expPosMat), deref(expHitsVec))
            chiArr = arma.mat2np(chiMat)

        finally:
            del paramsMat, expPosMat, expHitsVec

        return chiArr

    @property
    def num_iters(self):
        return self.thisptr.numIters

    @num_iters.setter
    def num_iters(self, newval):
        self.thisptr.numIters = newval

    @property
    def num_pts(self):
        return self.thisptr.numPts

    @num_pts.setter
    def num_pts(self, newval):
        self.thisptr.numPts = newval

    @property
    def red_factor(self):
        return self.thisptr.redFactor

    @red_factor.setter
    def red_factor(self, newval):
        self.thisptr.redFactor = newval

    @property
    def posChi2Enabled(self):
        return self.thisptr.posChi2Enabled

    @posChi2Enabled.setter
    def posChi2Enabled(self, newval):
        self.thisptr.posChi2Enabled = newval

    @property
    def enChi2Enabled(self):
        return self.thisptr.enChi2Enabled

    @enChi2Enabled.setter
    def enChi2Enabled(self, newval):
        self.thisptr.enChi2Enabled = newval

    @property
    def posChi2Norm(self):
        return self.thisptr.posChi2Norm

    @posChi2Norm.setter
    def posChi2Norm(self, newval):
        self.thisptr.posChi2Norm = newval

    @property
    def enChi2NormFraction(self):
        return self.thisptr.enChi2NormFraction

    @enChi2NormFraction.setter
    def enChi2NormFraction(self, newval):
        self.thisptr.enChi2NormFraction = newval
