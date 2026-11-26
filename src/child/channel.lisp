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

(defmacro %with-frame-syntax (&body body)
  "BODY under the frame syntax: standard syntax, *PACKAGE* KEYWORD,
   *READ-EVAL* NIL."
  `(with-standard-io-syntax
     (let ((*package* (find-package '#:keyword))
           (*read-eval* nil))
       ,@body)))

(defun frame-string (form)
  "FORM printed for a frame body (see the file header): standard syntax,
   *PACKAGE* KEYWORD, *PRINT-READABLY* T, *READ-EVAL* NIL. An unreadable value signals
   PRINT-NOT-READABLE. → a string."
  (%with-frame-syntax
    (let ((*print-readably* t))
      (prin1-to-string form))))

(defun write-frame (form stream)
  "Write FORM as one frame (see the file header) to STREAM, an output
   stream of (UNSIGNED-BYTE 8), then FINISH-OUTPUT. Nothing is written when
   FRAME-STRING signals. → FORM."
  ;; The body is printed (and may signal) before any byte is written; the
  ;; frame then goes out in one WRITE-SEQUENCE.
  (let* ((body (babel:string-to-octets (frame-string form) :encoding :utf-8))
         (header (babel:string-to-octets (format nil "~d~c" (length body) #\Newline)
                                         :encoding :ascii))
         (frame (make-array (+ (length header) (length body) 1)
                            :element-type '(unsigned-byte 8))))
    (replace frame header)
    (replace frame body :start1 (length header))
    (setf (aref frame (1- (length frame))) 10)
    (write-sequence frame stream)
    (finish-output stream)
    form))

(defun %channel-error (pathname offset control &rest arguments)
  (error 'channel-error :pathname pathname :offset offset
                        :message (apply #'format nil control arguments)))

(defun %read-file-octets (pathname offset)
  "The octets of PATHNAME from byte OFFSET to its current end, or NIL when
   the file does not exist."
  (with-open-file (in pathname :element-type '(unsigned-byte 8)
                               :if-does-not-exist nil)
    (when in
      (let* ((end (file-length in))
             (octets (make-array (max 0 (- end offset))
                                 :element-type '(unsigned-byte 8))))
        (when (plusp (length octets))
          (file-position in offset)
          (let ((n (read-sequence octets in)))
            (when (< n (length octets))
              (setf octets (subseq octets 0 n)))))
        octets))))

(defun %read-body (pathname offset octets start end)
  "The one form in OCTETS[START, END) (UTF-8), read under the frame syntax.
   Anything else signals CHANNEL-ERROR at OFFSET."
  (handler-case
      (let ((text (babel:octets-to-string octets :start start :end end
                                                 :encoding :utf-8)))
        (%with-frame-syntax
          (multiple-value-bind (form position) (read-from-string text)
            (let ((eof '#:eof))
              (unless (eq eof (read-from-string text nil eof :start position))
                (%channel-error pathname offset "the frame body is more than one form")))
            form)))
    ;; A translation site: the reader's and the decoder's own conditions
    ;; become the channel's, with their report.
    ((or reader-error end-of-file babel:character-coding-error) (c)
      (%channel-error pathname offset "the frame body is not one readable form: ~a" c))))

(defun read-frames (pathname offset)
  "Read the complete frames of the channel file PATHNAME that start at byte
   OFFSET or later. → (values FORMS NEW-OFFSET): FORMS in file order,
   NEW-OFFSET the byte just past the last complete frame read (OFFSET when
   there is none). An incomplete trailing frame is left for a later call.
   A missing file → (values NIL OFFSET). A header that is not decimal
   digits, a body that is not exactly one readable form, or a frame not
   ended by LF signals CHANNEL-ERROR (OFFSET = the bad frame's start)."
  (check-type offset (integer 0))
  (let ((octets (%read-file-octets pathname offset)))
    (if (null octets)
        (values nil offset)
        (let ((n (length octets)) (pos 0) (forms '()))
          (loop
            (when (>= pos n) (return))
            (let* ((start pos)
                   (lf (position 10 octets :start pos))
                   (header-end (or lf n)))
              ;; Any non-digit in the header is an error now, even before
              ;; its LF arrives; only a digits-only prefix is incomplete.
              (loop for i from start below header-end
                    unless (<= 48 (aref octets i) 57)
                      do (%channel-error pathname (+ offset start)
                                         "the frame header is not decimal digits"))
              (when (null lf) (return))
              (when (= lf start)
                (%channel-error pathname (+ offset start) "the frame header is empty"))
              (let* ((length (parse-integer
                              (babel:octets-to-string octets :start start :end lf
                                                             :encoding :ascii)))
                     (body (1+ lf))
                     (body-end (+ body length)))
                ;; Body or final LF not all there yet: incomplete.
                (when (>= body-end n) (return))
                (unless (= 10 (aref octets body-end))
                  (%channel-error pathname (+ offset start)
                                  "the frame is not ended by LF"))
                (push (%read-body pathname (+ offset start) octets body body-end) forms)
                (setf pos (1+ body-end)))))
          (values (nreverse forms) (+ offset pos))))))
