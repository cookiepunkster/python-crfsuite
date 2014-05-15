# cython: embedsignature=True
# cython: c_string_type=str, c_string_encoding=ascii
# cython: profile=False
from __future__ import print_function, absolute_import
cimport crfsuite_api
from libcpp.string cimport string

import sys
import os
import warnings
import traceback
import logging
import contextlib
import tempfile

from pycrfsuite import _dumpparser

logger = logging.getLogger('pycrfsuite')
CRFSUITE_VERSION = crfsuite_api.version()


class CRFSuiteError(Exception):

    _messages = {
        crfsuite_api.CRFSUITEERR_UNKNOWN: "Unknown error occurred",
        crfsuite_api.CRFSUITEERR_OUTOFMEMORY: "Insufficient memory",
        crfsuite_api.CRFSUITEERR_NOTSUPPORTED: "Unsupported operation",
        crfsuite_api.CRFSUITEERR_INCOMPATIBLE: "Incompatible data",
        crfsuite_api.CRFSUITEERR_INTERNAL_LOGIC: "Internal error",
        crfsuite_api.CRFSUITEERR_OVERFLOW: "Overflow",
        crfsuite_api.CRFSUITEERR_NOTIMPLEMENTED: "Not implemented",
    }

    def __init__(self, code):
        self.code = code
        Exception.__init__(self._messages.get(self.code, "Unexpected error"))


cdef crfsuite_api.ItemSequence to_seq(pyseq) except+:
    """
    Convert an iterable to an ItemSequence.
    Elements of an iterable could be either dicts {unicode_key: float_value}
    or strings.
    """
    cdef crfsuite_api.ItemSequence c_seq

    cdef crfsuite_api.Item c_item
    cdef double c_value
    cdef string c_key
    cdef bint is_dict

    for x in pyseq:
        is_dict = isinstance(x, dict)
        c_item = crfsuite_api.Item()
        c_item.reserve(len(x))
        for key in x:
            c_key = (<unicode>key).encode('utf8') if isinstance(key, unicode) else key
            c_value = x[key] if is_dict else 1.0
            c_item.push_back(crfsuite_api.Attribute(c_key, c_value))
        c_seq.push_back(c_item)

    return c_seq


def _intbool(txt):
    return bool(int(txt))

cdef class Trainer(object):
    """
    The trainer class.

    This class maintains a data set for training, and provides an interface
    to various training algorithms.
    """
    cdef crfsuite_api.Trainer c_trainer

    _PARAMETER_TYPES = {
        'feature.minfreq': float,
        'feature.possible_states': _intbool,
        'feature.possible_transitions': _intbool,
        'c1': float,
        'c2': float,
        'max_iterations': int,
        'num_memories': int,
        'epsilon': float,
        'period': int,  # XXX: is it called 'stop' in docs?
        'delta': float,
        'linesearch': str,
        'max_linesearch': int,
        'calibration.eta': float,
        'calibration.rate': float,
        'calibration.samples': float,
        'calibration.candidates': int,
        'calibration.max_trials': int,
        'type': int,
        'c': float,
        'error_sensitive': _intbool,
        'averaging': _intbool,
        'variance': float,
        'gamma': float,
    }

    _ALGORITHM_ALIASES = {
        'ap': 'averaged-perceptron',
        'pa': 'passive-aggressive',
    }

    def __init__(self, algorithm=None, params=None):
        if algorithm is not None:
            self.select(algorithm)
        if params is not None:
            self.set_params(params)

    def __cinit__(self):
        # setup message handler
        self.c_trainer.set_handler(self, <crfsuite_api.messagefunc>self._on_message)

        # fix segfaults, see https://github.com/chokkan/crfsuite/pull/21
        self.c_trainer.select("lbfgs", "crf1d")
        self.c_trainer._init_hack()

    cdef _on_message(self, string message):
        try:
            self.message(message)
        except:
            # catch all errors to avoid segfaults
            warnings.warn("\n\n** Exception in on_message handler is ignored:\n" +
                          traceback.format_exc())

    def message(self, message):
        """
        Receive messages from the training algorithm.
        Override this method to receive messages of the training
        process.

        By default, this method uses Python logging subsystem to
        output the messages (logger name is 'pycrfsuite').

        Parameters
        ----------
        message : string
            The message
        """
        logger.info(message)

    def append(self, xseq, yseq, int group=0):
        """
        Append an instance (item/label sequence) to the data set.

        Parameters
        ----------
        xseq : a sequence of item features
            The item sequence of the instance. Features for an item
            can be represented either by a ``{key1: weight1, key2: weight2, ..}``
            dict (a string -> float mapping where keys are observed features
            and values are their weights) or by a ``[key1, key2, ...]``
            list - all weights are considered 1.0 in this case.

        yseq : a sequence of strings
            The label sequence of the instance. The number
            of elements in yseq must be identical to that
            in xseq.

        group : int, optional
            The group number of the instance. Group numbers are used to
            select subset of data for heldout evaluation.
        """
        self.c_trainer.append(to_seq(xseq), yseq, group)

    def select(self, algorithm, type='crf1d'):
        """
        Initialize the training algorithm.

        Parameters
        ----------
        algorithm : {'lbfgs', 'l2sgd', 'ap', 'pa', 'arow'}
            The name of the training algorithm.

            * 'lbfgs' for Gradient descent using the L-BFGS method,
            * 'l2sgd' for Stochastic Gradient Descent with L2 regularization term
            * 'ap' for Averaged Perceptron
            * 'pa' for Passive Aggressive
            * 'arow' for Adaptive Regularization Of Weight Vector

        type : string, optional
            The name of the graphical model.
        """
        algorithm = algorithm.lower()
        algorithm = self._ALGORITHM_ALIASES.get(algorithm, algorithm)
        if not self.c_trainer.select(algorithm, type):
            raise ValueError(
                "Bad arguments: algorithm=%r, type=%r" % (algorithm, type)
            )

    def train(self, model, int holdout=-1):
        """
        Run the training algorithm.
        This function starts the training algorithm with the data set given
        by :meth:`Trainer.append_dicts` or :meth:`Trainer.append_stringlists`
        methods.

        Parameters
        ----------
        model : string
            The filename to which the trained model is stored.
            If this value is empty, this function does not
            write out a model file.

        holdout : int, optional
            The group number of holdout evaluation. The
            instances with this group number will not be used
            for training, but for holdout evaluation.
            Default value is -1, meaning "use all instances for training".
        """
        status_code = self.c_trainer.train(model, holdout)
        if status_code != crfsuite_api.CRFSUITE_SUCCESS:
            raise CRFSuiteError(status_code)

    def params(self):
        """
        Obtain the list of parameters.

        This function returns the list of parameter names available for the
        graphical model and training algorithm specified by
        :meth:`Trainer.select` method.

        Returns
        -------
        list of strings
            The list of parameters available for the current
            graphical model and training algorithm.

        """
        return self.c_trainer.params()

    def set_params(self, params):
        """
        Set training parameters.

        Parameters
        ----------
        params : dict
            A dict with parameters ``{name: value}``
        """
        for key, value in params.items():
            self.set(key, value)

    def set(self, name, value):
        """
        Set a training parameter.
        This function sets a parameter value for the graphical model and
        training algorithm specified by :meth:`Trainer.select` method.

        Parameters
        ----------
        name : string
            The parameter name.
        value : string
            The value of the parameter.

        """
        if isinstance(value, bool):
            value = int(value)
        self.c_trainer.set(name, str(value))

    def get(self, name):
        """
        Get the value of a training parameter.
        This function gets a parameter value for the graphical model and
        training algorithm specified by :meth:`Trainer.select` method.

        Parameters
        ----------
        name : string
            The parameter name.
        """
        return self._cast_parameter(name, self.c_trainer.get(name))

    def help(self, name):
        """
        Get the description of a training parameter.
        This function obtains the help message for the parameter specified
        by the name. The graphical model and training algorithm must be
        selected by :meth:`Trainer.select` method before calling this method.

        Parameters
        ----------
        name : string
            The parameter name.

        Returns
        -------
        string
            The description (help message) of the parameter.

        """
        if name not in self.params():
            # c_trainer.help(name) segfaults without this workaround;
            # see https://github.com/chokkan/crfsuite/pull/21
            raise ValueError("Parameter not found: %s" % name)
        return self.c_trainer.help(name)

    def clear(self):
        """ Remove all instances in the data set. """
        self.c_trainer.clear()

    def _cast_parameter(self, name, value):
        if name in self._PARAMETER_TYPES:
            return self._PARAMETER_TYPES[name](value)
        return value


cdef class Tagger(object):
    """
    The tagger class.

    This class provides the functionality for predicting label sequences for
    input sequences using a model.
    """
    cdef crfsuite_api.Tagger c_tagger

    def open(self, name):
        """
        Open a model file.

        Parameters
        ----------
        name : string
            The file name of the model file.

        """
        # We need to do some basic checks ourselves because crfsuite
        # may segfault if the file is invalid.
        # See https://github.com/chokkan/crfsuite/pull/24
        self._check_model(name)
        if not self.c_tagger.open(name):
            raise ValueError("Error opening model file %r" % name)
        return contextlib.closing(self)

    def close(self):
        """
        Close the model.
        """
        self.c_tagger.close()

    def labels(self):
        """
        Obtain the list of labels.

        Returns
        -------
        list of strings
            The list of labels in the model.
        """
        return self.c_tagger.labels()

    def tag(self, xseq=None):
        """
        Predict the label sequence for the item sequence.

        Parameters
        ----------
        xseq : item sequence, optional
            The item sequence. If omitted, the current sequence is used
            (a sequence set using :meth:`Tagger.set` method or
            a sequence used in a previous :meth:`Tagger.tag` call).

            Features for each item can be represented either by
            a ``{key1: weight1, key2: weight2, ..}`` dict
            (a string -> float mapping where keys are observed features
            and values are their weights) or by a ``[key1, key2, ...]``
            list - all weights are considered 1.0 in this case.

        Returns
        -------
        list of strings
            The label sequence predicted.
        """
        if xseq is not None:
            self.set(xseq)

        return self.c_tagger.viterbi()

    def probability(self, yseq):
        """
        Compute the probability of the label sequence for the current input
        sequence (a sequence set using :meth:`Tagger.set` method or
        a sequence used in a previous :meth:`Tagger.tag` call).

        Parameters
        ----------
        yseq : list of strings
            The label sequence.

        Returns
        -------
        float
            The probability ``P(yseq|xseq)``.
        """
        return self.c_tagger.probability(yseq)

    def marginal(self, y, pos):
        """
        Compute the marginal probability of the label ``y`` at position ``pos``
        for the current input sequence (i.e. a sequence set using
        :meth:`Tagger.set` method or a sequence used in a previous
        :meth:`Tagger.tag` call).

        Parameters
        ----------
        y : string
            The label.
        t : int
            The position of the label.

        Returns
        -------
        float
            The marginal probability of the label ``y`` at position ``t``.
        """
        return self.c_tagger.marginal(y, pos)

    cpdef set(self, xseq) except +:
        """
        Set an instance (item sequence) for future calls of
        :meth:`Tagger.tag`, :meth:`Tagger.probability`
        and :meth:`Tagger.marginal` methods.

        Parameters
        ----------
        xseq : item sequence
            The item sequence. If omitted, the current sequence is used
            (e.g. a sequence set using :meth:`Tagger.set` method).

            Features for each item can be represented either by
            a ``{key1: weight1, key2: weight2, ..}`` dict
            (a string -> float mapping where keys are observed features
            and values are their weights) or by a ``[key1, key2, ...]``
            list - all weights are considered 1.0 in this case.

        """
        self.c_tagger.set(to_seq(xseq))

    def dump(self, filename=None):
        """
        Dump a CRF model in plain-text format.

        Parameters
        ----------
        filename : string, optional
            File name to dump the model to.
            If None, the model is dumped to stdout.
        """
        if filename is None:
            self.c_tagger.dump(os.dup(sys.stdout.fileno()))
        else:
            fd = os.open(filename, os.O_CREAT | os.O_WRONLY)
            try:
                self.c_tagger.dump(fd)
            finally:
                try:
                    os.close(fd)
                except OSError:
                    pass  # already closed by Tagger::dump

    def info(self):
        """
        Return a :class:`~.ParsedDump` structure with model internal information.
        """
        parser = _dumpparser.CRFsuiteDumpParser()
        fd, name = tempfile.mkstemp()
        try:
            self.c_tagger.dump(fd)
            with open(name, 'rb') as f:
                for line in f:
                    parser.feed(line.decode('utf8'))
        finally:
            os.unlink(name)
        return parser.result

    def _check_model(self, name):
        # See https://github.com/chokkan/crfsuite/pull/24
        # 1. Check that the file can be opened.
        with open(name, 'rb') as f:

            # 2. Check that file magic is correct.
            magic = f.read(4)
            if magic != b'lCRF':
                raise ValueError("Invalid model file %r" % name)

            # 3. Make sure crfsuite won't read past allocated memory
            # in case of incomplete header.
            f.seek(0, os.SEEK_END)
            size = f.tell()
            if size <= 48:  # header size
                raise ValueError("Model file %r doesn't have a complete header" % name)
