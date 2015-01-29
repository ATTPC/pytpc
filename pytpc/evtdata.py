"""
evtdata
=======

This module provides functionality for interacting with GET event files. These files contain merged events.

..  Note::
    This module does *not* allow interaction with un-merged GRAW files.

Examples
--------

..  code-block:: python

    from pytpc.evtdata import EventFile, Event

    # Open a file
    ef = EventFile('/path/to/data.evt')

    # Read the fourth event
    evt = ef[4]

    # Iterate over all events
    for evt in ef:
        do_something(evt)

    # Slices are also supported
    for evt in ef[4:20]:
        do_something(evt)

"""

import struct
import numpy
import os.path
from .tpcplot import generate_pad_plane


class EventFile:
    """Represents a merged GET event file.

    This class provides an interface to merged event files from the GET electronics. It is capable of opening
    merged data files and reading events from them.

    When an event file is first opened, its contents are automatically indexed. The generated lookup table is saved
    in the same directory as the event file, but with the extension ".lookup".

    The events can be accessed with the methods beginning with "read". Additionally, this class supports both
    iteration and subscripting.
    """

    def __init__(self, filename=None):
        """ Initializes and, optionally, opens an event file.

        If a filename is provided, that file will be opened.

        **Arguments**

        filename : string
            The name of the file to open.
        """

        self.magic = 0x6e7ef11e  # The file's magic number

        self.lookup = []
        """A lookup table for the events in the file. This is simply an array of file offsets."""

        self.current_event = 0  #: The current event

        if filename is not None:
            self.open(filename)
            ltfilename = os.path.splitext(filename)[0] + '.lookup'
            if os.path.exists(ltfilename):
                self.load_lookup_table(ltfilename)
            else:
                self.make_lookup_table()
            self.is_open = True

        else:
            self.fp = None
            self.is_open = False

        return

    def open(self, filename):
        """ Opens the specified file.

        The file's first 4 bytes are compared to the magic value ``0x6e7ef11e`` to check that the file is of the
        correct type.

        **Arguments**

        filename : string
            The name of the file to open
        """

        try:
            self.fp = open(filename, 'rb')
            self.is_open = True
            print("Opened file: " + filename)

            read_magic = struct.unpack('<I', self.fp.read(4))[0]
            if read_magic != self.magic:
                print("Bad file. Magic number is wrong.")

        except IOError:
            raise

        return

    def close(self):
        """Close an open file"""

        if self.is_open:
            self.fp.close()
            self.is_open = False

        return

    @staticmethod
    def pack_sample(tb, val):
        """Pack a sample value into three bytes.

        See the documentation of the Event File format for details.

        **Arguments**

        tb : int
            The time bucket
        val : int
            The sample

        **Returns**

        joined : int
            The packed sample
        """

        # val is 12-bits and tb is 9 bits. Fit this in 24 bits.
        # Use one bit for parity

        if val < 0:
            parity = 1 << 12
            narrowed = -val
        elif val >= 4095:
            parity = 0
            narrowed = 4095
        else:
            parity = 0
            narrowed = val

        joined = (tb << 15) | narrowed | parity
        return joined

    @staticmethod
    def unpack_sample(packed):
        """Unpacks a packed time bucket / sample pair.

        **Arguments**

        packed : int
            The packed value

        **Returns**

        tb : int
            The time bucket
        sample : int
            The sample value
        """

        tb = (packed & 0xFF8000) >> 15
        sample = (packed & 0xFFF)
        parity = (packed & 0x1000) >> 12

        if parity == 1:
            sample *= -1

        return tb, sample

    @staticmethod
    def unpack_samples(packed):
        """ Unpacks an array of time bucket / sample pairs.

        This is really just a modified version of unpack_sample that works with arrays.

        **Arguments**

        packed : array-like
            The packed values

        **Returns**

        samples : numpy.ndarray
            The sample values, indexed by time bucket
        """

        # TODO: Merge this into the unpack_sample method?

        tbs = (packed & 0xFF8000) >> 15
        samples = (packed & 0xFFF)
        parities = (packed & 0x1000) >> 12

        # Change the parities from (0, 1, ...) to (1, -1, ...) and multiply
        samples *= (-2 * parities + 1)

        unpacked = numpy.hstack((tbs, samples))
        result = numpy.zeros(512)

        for item in unpacked:
            result[item[0]] = item[1]

        return result

    def _read(self):
        """Reads an event at the current file position.

        The position is checked by checking the event magic number ``0xEE``.

        **Returns**

        event : instance of :class:`Event`
            The read event
        """

        assert self.is_open

        try:
            # Read the event header
            # This has the following structure:
            #     (magic, size, ID, ts, nTraces)
            hdr = struct.unpack('<BIIQH', self.fp.read(19))

            if hdr[0] != 0xEE:
                # This is not the beginning of the event. Seek back and fail.
                self.fp.seek(-19, 1)
                raise FilePosError(self.fp.name, "Event magic number was wrong.")

            event_size = hdr[1]
            event_id = hdr[2]
            event_ts = hdr[3]
            num_traces = hdr[4]

            new_evt = Event(evt_id=event_id, timestamp=event_ts)
            new_evt.traces = numpy.zeros((num_traces,), dtype=new_evt.dt)

            # Read the traces

            for n in range(num_traces):
                # Read the trace header. The structure of this is:
                #    (size, cobo, asad, aget, ch, pad)
                th = struct.unpack('<IBBBBH', self.fp.read(10))

                tr = new_evt.traces[n]

                tr['cobo'] = th[1]
                tr['asad'] = th[2]
                tr['aget'] = th[3]
                tr['channel'] = th[4]
                tr['pad'] = th[5]

                # Now read the trace itself
                num_samples = (th[0] - 10) // 3  # (total - header) / size of packed item

                packed = numpy.hstack((numpy.fromfile(self.fp, dtype='3u1', count=num_samples),
                                       numpy.zeros((num_samples, 1), dtype='u1'))).view('<u4')

                unpacked = self.unpack_samples(packed)
                tr['data'][:] = unpacked

            return new_evt

        except Error as er:
            raise er

    def make_lookup_table(self):
        """ Indexes the open file and generates a lookup table.

        The lookup table is a list of the file offsets of each event, in bytes. This is used by the read_next() and
        read_previous() functions to navigate around the file. The table is returned, but it is also assigned to
        self.lookup.

        **Returns**
        lookup : list
            The lookup table
        """

        assert self.is_open

        self.fp.seek(4)

        self.lookup = []

        while True:
            magic = self.fp.read(1)
            if magic == b'\xEE':
                pos = self.fp.tell() - 1
                self.lookup.append(pos)
                offset = struct.unpack('<I', self.fp.read(4))[0]
                self.fp.seek(pos + offset)
            elif magic == b'':
                break
            else:
                print("Bad magic number")
                return None

        self.fp.seek(4)
        self.current_event = 0

        ltfilename = os.path.splitext(self.fp.name)[0] + '.lookup'

        if not os.path.exists(ltfilename):
            ltfile = open(ltfilename, 'w')
            for entry in self.lookup:
                ltfile.write(str(entry) + '\n')
            ltfile.close()

        return self.lookup

    def load_lookup_table(self, filename):
        """Read a lookup table from a file.

        The file should contain the (integer) file offsets, with one on each line.

        **Arguments**

        filename : string
            The path to the file.
        """

        self.lookup = []

        try:
            file = open(filename, 'r')
            for line in file:
                self.lookup.append(int(line.rstrip()))
        except FileNotFoundError:
            print("File name was not valid")
            return

    def read_next(self):
        """Read the next event in the file.

        This function reads the next event from the file and increments the self.current_event value. For example,
        if the current_event is 4, then current_event will be set to 5, and event 5 will be read and returned.

        **Returns**

        evt : instance of :class:`Event`
            The next event in the file
        """

        if self.current_event + 1 < len(self.lookup):
            self.current_event += 1
            self.fp.seek(self.lookup[self.current_event])
            return self._read()
        else:
            print("At last event")
            return None

    def read_current(self):
        """Read the event currently pointed to by the current_event marker.

        This function reads the current event from the file. For example, if the current_event is 4, then event 4
        will be read and returned.

        **Returns**

        evt : instance of :class:`Event`
            The current event
        """

        self.fp.seek(self.lookup[self.current_event])
        return self._read()

    def read_previous(self):
        """Read the previous event from the file.

        This function reads the previous event from the file and decrements the self.current_event value. For example,
        if the current_event is 4, then current_event will be set to 3, and event 3 will be read and returned.

        **Returns**

        evt : instance of :class:`Event`
            The previous event from the file
        """

        if self.current_event - 1 >= 0:
            self.current_event -= 1
            self.fp.seek(self.lookup[self.current_event])
            return self._read()
        else:
            print("At first event")
            return None

    def read_event_by_number(self, num):
        """Reads a specific event from the file, based on its event number.

        This function uses the lookup table to find the requested event in the file, and then reads and returns that
        event. The current_event index is updated to the event number that was requested.

        **Arguments**

        num : int
            The event number to read. This should be an index in the bounds of :attr:`lookup`

        **Returns**

        evt : instance of :class:`Event`
            The requested event from the file
        """

        if 0 <= num < len(self.lookup):
            self.current_event = num
            self.fp.seek(self.lookup[num])
            return self._read()
        else:
            print("The provided number is outside the range of event numbers.")
            return None

    def __iter__(self):
        """ Prepare the file object for iteration.

        This sets the current event to 0 and rewinds the file pointer back to the beginning.
        """
        self.fp.seek(self.lookup[0])
        self.current_event = 0
        return self

    def __next__(self):
        """ Get the next event when iterating.
        """

        if self.current_event < len(self.lookup):
            evt = self.read_current()
            self.current_event += 1
            return evt
        else:
            raise StopIteration

    def __getitem__(self, item):
        """ Implements subscripting of the event file, with slices.
        """

        if isinstance(item, slice):
            start, stop, step = item.indices(len(self.lookup))
            evts = []
            for i in range(start, stop, step):
                e = self.read_event_by_number(i)
                evts.append(e)
            return evts

        elif isinstance(item, int):
            if item < 0 or item > len(self.lookup):
                raise IndexError("The index is out of bounds")
            else:
                return self.read_event_by_number(item)

        else:
            raise IndexError("index must be int or slice")


class Event:
    """ Represents an event from an :class:`EventFile`.

    The event is represented as a numpy array with a complex dtype.
    """

    def __init__(self, evt_id=0, timestamp=0):
        """ Initialize a new event.

        **Arguments**

        evt_id : int
            The event ID
        timestamp : int
            The event timestamp
        """
        assert (evt_id >= 0)
        assert (timestamp >= 0)

        self.dt = numpy.dtype([('cobo', 'u1'), ('asad', 'u1'), ('aget', 'u1'), ('channel', 'u1'),
                               ('pad', 'u2'), ('data', '512i2')])
        """The data type of the numpy array"""

        self.evt_id = evt_id
        """The event ID"""

        self.timestamp = timestamp
        """The event timestamp"""

        self.traces = numpy.zeros((0,), dtype=self.dt)
        """The event data. The dtype is :attr:`dt`."""

        return

    def __str__(self):
        str = 'Event {id}, timestamp {ts}.\nContains {tr} traces.'
        return str.format(id=self.evt_id, ts=self.timestamp, tr=len(self.traces))

    def hits(self):
        """ Calculate the total activation of each pad.

        The activation is calculated by summing the activation for all time buckets in each channel.

        **Returns**

        hits : numpy.ndarray
            An array of hits, indexed by pad number
        """

        hits = self.traces['data'].sum(1)
        pads = self.traces['pad']

        flat_hits = numpy.zeros(10240)
        for (p, h) in zip(pads, hits):
            flat_hits[p] = h

        return flat_hits

    def xyzs(self):
        """ Find the scatter points of the event in space.

        **Returns**

        xyzs : numpy.ndarray
            A 4D array of points including (x, y, tb, activation)
        """

        nz = self.traces['data'].nonzero()
        pcenters = generate_pad_plane().mean(1)

        xys = numpy.array([pcenters[self.traces[i]['pad']] for i in nz[0]])
        zs = nz[1].reshape(nz[1].shape[0], 1)
        cs = self.traces['data'][nz].reshape(nz[0].shape[0], 1)

        result = numpy.hstack((xys, zs, cs))
        return result


def load_pedestals(filename):
    """ Loads pedestals from the provided file.

    The pedestals file should be in CSV format, and the columns should be cobo, asad, aget, and channel.

    **Arguments**

    filename : string
        The name of the file containing the pedestals.

    **Returns**

    peds : numpy.ndarray
        The pedestals, in a 4D array with the same indices as above.
    """

    f = open(filename, 'r')
    peds = numpy.zeros((10, 4, 4, 68, 512))

    for line in f:
        subs = line[:-1].split(',')  # throw out the newline and split at commas
        vals = [int(float(x)) for x in subs]
        peds[(vals[0], vals[1], vals[2], vals[3])] = vals[4] * numpy.ones(512)

    return peds


def load_padmap(filename):
    """Loads pad mapping from the provided file.

    **Arguments**

    filename : string
        The name of the file containing the pad mapping

    **Returns**

    pm : dictionary
        The pad mapping as {(cobo, asad, aget, ch): pad}
    """

    f = open(filename, 'r')
    pm = {}

    for line in f:
        subs = line[:-1].split(',')  # throw out the newline and split at commas
        vals = [int(float(x)) for x in subs]
        pm[(vals[0], vals[1], vals[2], vals[3])] = vals[4]

    return pm


class Error(Exception):
    """Base class for custom exceptions."""
    pass


class FilePosError(Error):
    """Raised when data is read from a file whose read pointer does not seem
    to be in the correct position.
    """

    def __init__(self, filename, details=""):
        self.filename = filename  #: The name of the file where the error occurred
        self.details = details    #: Details of the error
        self.message = "FilePosError in " + filename + ": " + details  # An error message for printing