(defpackage #:task-worker-process/child
  (:use #:cl)
  (:export #:channel-error
           #:channel-error-pathname
           #:channel-error-offset
           #:channel-error-message

           #:+request-file+
           #:+channel-file+
           #:+cancel-file+
           #:+log-file+
           #:+boot-file+

           #:frame-string
           #:write-frame
           #:read-frames
           #:child-main))

(in-package #:task-worker-process/child)

;;; 0.1.0 (given): the child side of task-worker-process. A child Lisp
;;; loads only this system (and babel), then the handler's systems; it never
;;; loads task-protocol or process-protocol. The parent loads it too, for
;;; the frame reader and the file names below.

(defparameter +request-file+ "request.sexp"
  "In the job directory: the request the parent writes before the launch.")

(defparameter +channel-file+ "channel"
  "In the job directory: the frames the child writes (see channel.lisp).")

(defparameter +cancel-file+ "cancel"
  "In the job directory: created by the parent when the job's cancel is
   requested. The child's CANCEL-REQUESTED-P is (PROBE-FILE <it>).")

(defparameter +log-file+ "child.log"
  "In the job directory: the child's stdout and stderr, together.")

(defparameter +boot-file+ "boot.lisp"
  "In the job directory: the file the child command LOADs.")

(define-condition channel-error (error)
  ((pathname :initarg :pathname :initform nil :reader channel-error-pathname)
   (offset :initarg :offset :initform nil :reader channel-error-offset
           :documentation "Byte offset of the bad frame.")
   (message :initarg :message :initform nil :reader channel-error-message))
  (:report (lambda (c s)
             (format s "task-worker-process channel ~@[~a ~]at byte ~d: ~a"
                     (and (channel-error-pathname c)
                          (namestring (channel-error-pathname c)))
                     (channel-error-offset c)
                     (channel-error-message c))))
  (:documentation "A malformed frame: a bad header, or a body that is not
   one readable form."))

(defun %pending (name)
  "The stub of every 0.1.0 child operation not implemented yet."
  (error "task-worker-process 0.1.0: ~(~a~) is not implemented yet" name))
