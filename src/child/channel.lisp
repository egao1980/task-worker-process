(in-package #:task-worker-process/child)

;;; 0.1.0 channel (contract): child → parent frames in a file.
;;;
;;; Why a file and not the child's stdout
;;; -------------------------------------
;;; Handler code and the libraries it loads print to *STANDARD-OUTPUT* (and
;;; foreign code writes to fd 1); on stdout that output would interleave
;;; with the frames. A file the child opens itself carries frames only,
;;; while stdout and stderr go to +LOG-FILE+ for diagnosis. The parent
;;; already polls each running job (cancel flag, timeout, lease heartbeat,
;;; exit), so it reads new frames in the same loop: no reader thread, no
;;; pipe buffer that blocks the child when the parent is slow, the same on
;;; Windows, and the frames written before a crash stay on disk.
;;;
;;; Frame format
;;; ------------
;;; A frame is one Lisp form F, written as
;;;
;;;   <N in ASCII decimal digits> LF <N bytes: UTF-8 of (FRAME-STRING F)> LF
;;;
;;; The byte count makes a frame self-delimiting whatever F contains
;;; (strings with newlines, any character). A reader never consumes a
;;; frame whose header, body or final LF is not all in the file yet: a
;;; frame being written is simply not there yet. Frames are appended by one
;;; writer (the child), each followed by FINISH-OUTPUT.
;;;
;;; FRAME-STRING prints under WITH-STANDARD-IO-SYNTAX with *PACKAGE* the
;;; KEYWORD package, *PRINT-READABLY* T and *READ-EVAL* NIL (no #. syntax:
;;; SBCL would otherwise print a hash table as #.(…)), so a value that cannot be read
;;; back (a hash table, a CLOS instance, a function) signals
;;; PRINT-NOT-READABLE instead of writing an unreadable frame. The reader
;;; uses the same syntax with *READ-EVAL* NIL. So the values that cross the
;;; channel (payloads, results, progress fields) are numbers, characters,
;;; strings, symbols (whose package exists in the reading image), conses and
;;; arrays of those: the values task-protocol's CANONICALIZE-VALUE accepts,
;;; minus hash tables (task-backend-sql refuses those too).
;;;
;;; Frames the child writes (keywords as shown, any order of plist keys):
;;;   (:progress :phase P :fraction F :message M)   REPORT-PROGRESS
;;;   (:result V)                                   the handler returned V
;;;   (:error :type "PKG::NAME" :message "…" :heap-exhausted BOOL)
;;;       the handler (or loading its systems) signalled a condition; TYPE
;;;       is the condition's class name printed with its package, MESSAGE
;;;       its report; HEAP-EXHAUSTED is T for heap exhaustion (on SBCL a
;;;       SB-KERNEL::HEAP-EXHAUSTED-ERROR, a STORAGE-CONDITION).
;;; At most one :result or :error frame, and it is the last frame.

(defun frame-string (form)
  "FORM printed for a frame body (see the file header): standard syntax,
   *PACKAGE* KEYWORD, *PRINT-READABLY* T, *READ-EVAL* NIL. An unreadable value signals
   PRINT-NOT-READABLE. → a string."
  (declare (ignore form))
  (%pending 'frame-string))

(defun write-frame (form stream)
  "Write FORM as one frame (see the file header) to STREAM, an output
   stream of (UNSIGNED-BYTE 8), then FINISH-OUTPUT. Nothing is written when
   FRAME-STRING signals. → FORM."
  (declare (ignore form stream))
  (%pending 'write-frame))

(defun read-frames (pathname offset)
  "Read the complete frames of the channel file PATHNAME that start at byte
   OFFSET or later. → (values FORMS NEW-OFFSET): FORMS in file order,
   NEW-OFFSET the byte just past the last complete frame read (OFFSET when
   there is none). An incomplete trailing frame is left for a later call.
   A missing file → (values NIL OFFSET). A header that is not decimal
   digits, a body that is not exactly one readable form, or a frame not
   ended by LF signals CHANNEL-ERROR (OFFSET = the bad frame's start)."
  (declare (ignore pathname offset))
  (%pending 'read-frames))
