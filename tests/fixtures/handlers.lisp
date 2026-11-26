(defpackage #:twp-test-handlers
  (:use #:cl)
  (:export #:echo #:progress #:report-pid-and-sleep #:cooperative #:hog
           #:crash #:fail #:slow-echo #:heap-size))

(in-package #:twp-test-handlers)

;;; Handlers for the task-worker-process tests. They run in child SBCLs
;;; only (SB-UNIX:UNIX-GETPID, SB-EXT:DYNAMIC-SPACE-SIZE).

(defun %getpid ()
  #+sbcl (sb-unix:unix-getpid)
  #-sbcl (error "the test handlers need SBCL"))

(defun %report-pid (report)
  (funcall report :phase "pid" :message (princ-to-string (%getpid))))

(defun echo (payload &key report-progress cancel-requested-p)
  (declare (ignore report-progress cancel-requested-p))
  (list :echo payload))

(defun progress (payload &key report-progress cancel-requested-p)
  "Reports (GETF PAYLOAD :STEPS) progress events, then returns :DONE."
  (declare (ignore cancel-requested-p))
  (let ((n (getf payload :steps)))
    (loop for i from 1 to n
          do (funcall report-progress :phase "step" :fraction (/ i n)
                                      :message (format nil "step ~d" i)))
    :done))

(defun report-pid-and-sleep (payload &key report-progress cancel-requested-p)
  "Reports its pid, then sleeps (GETF PAYLOAD :SECONDS 600) ignoring any
   cancel request."
  (declare (ignore cancel-requested-p))
  (%report-pid report-progress)
  (sleep (getf payload :seconds 600))
  :woke-up)

(defun cooperative (payload &key report-progress cancel-requested-p)
  "Reports its pid, then polls CANCEL-REQUESTED-P for up to 120 s and
   returns :STOPPED once it is true."
  (declare (ignore payload))
  (%report-pid report-progress)
  (loop repeat 2400
        when (funcall cancel-requested-p)
          do (return-from cooperative :stopped)
        do (sleep 0.05))
  :never-canceled)

(defun hog (payload &key report-progress cancel-requested-p)
  "Conses 1 MB vectors and keeps them (locally, so an unwind frees them)
   until the heap is exhausted."
  (declare (ignore payload report-progress cancel-requested-p))
  (let ((hoard '()))
    (loop (push (make-array (* 1024 1024) :element-type '(unsigned-byte 8)
                                          :initial-element 1)
                hoard))))

(defun crash (payload &key report-progress cancel-requested-p)
  "Exits the process with code 3 at once: no frame, no unwinding."
  (declare (ignore payload report-progress cancel-requested-p))
  #+sbcl (sb-ext:exit :code 3 :abort t)
  #-sbcl (uiop:quit 3 nil))

(defun fail (payload &key report-progress cancel-requested-p)
  (declare (ignore report-progress cancel-requested-p))
  (error "boom: ~a" payload))

(defun slow-echo (payload &key report-progress cancel-requested-p)
  "Sleeps (GETF PAYLOAD :SECONDS), then returns (:SLEPT payload)."
  (declare (ignore report-progress cancel-requested-p))
  (sleep (getf payload :seconds))
  (list :slept payload))

(defun heap-size (payload &key report-progress cancel-requested-p)
  "This child's dynamic space, in MB."
  (declare (ignore payload report-progress cancel-requested-p))
  #+sbcl (floor (sb-ext:dynamic-space-size) (* 1024 1024))
  #-sbcl nil)
