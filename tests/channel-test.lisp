(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: the channel frame format (src/child/channel.lisp). No
;;; child process here.

(defun %temp-file (name)
  (let ((p (merge-pathnames name (ensure-directories-exist
                                  (merge-pathnames "channel-tests/" *test-work-root*)))))
    (uiop:delete-file-if-exists p)
    p))

(defun %write-frames (path &rest forms)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8)
                          :if-exists :append :if-does-not-exist :create)
    (dolist (f forms) (wc:write-frame f s))))

(defun %append-octets (path octets)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8)
                          :if-exists :append :if-does-not-exist :create)
    (write-sequence octets s)))

(defun %file-length (path)
  (with-open-file (s path :element-type '(unsigned-byte 8)) (file-length s)))

(deftest frame-string-uses-standard-syntax
  (ok (equal "(:RESULT 1/2 \"a\")" (wc:frame-string '(:result 1/2 "a"))))
  (ok (equal "(:X COMMON-LISP:CAR)" (let ((*package* (find-package :cl)))
                                      (wc:frame-string '(:x car))))
      "symbols print with their package, whatever *PACKAGE* is")
  (ok (typep (%catch (lambda () (wc:frame-string (list :result (make-hash-table)))))
             'print-not-readable)))


(deftest frames-round-trip-exactly
  (let* ((path (%temp-file "round-trip"))
         (value (list :text (format nil "héllo~%world ✓") :n 42 :f 1.5d0
                      :r 2/3 :v #(1 2 3) :s "" :nested '((1 2) ("x"))))
         (frames (list (list :progress :phase "a" :fraction 0 :message nil)
                       (list :result value))))
    (apply #'%write-frames path frames)
    (multiple-value-bind (forms offset) (wc:read-frames path 0)
      (ok (equalp frames forms))
      (ok (= offset (%file-length path))))
    (multiple-value-bind (forms offset) (wc:read-frames path (%file-length path))
      (ok (null forms) "nothing after the last frame")
      (ok (= offset (%file-length path))))))

(deftest read-frames-leaves-an-incomplete-frame
  (let* ((path (%temp-file "partial"))
         (body (babel:string-to-octets (wc:frame-string '(:result "ünïcode"))
                                       :encoding :utf-8))
         (header (babel:string-to-octets (format nil "~d~c" (length body) #\Newline)
                                         :encoding :ascii)))
    (%write-frames path '(:progress :phase 1 :fraction nil :message nil))
    (let ((first-end (%file-length path)))
      ;; header and half the body: not a frame yet
      (%append-octets path header)
      (%append-octets path (subseq body 0 5))
      (multiple-value-bind (forms offset) (wc:read-frames path 0)
        (ok (equal '((:progress :phase 1 :fraction nil :message nil)) forms))
        (ok (= offset first-end)))
      ;; the whole body but not the final LF: still not a frame
      (%append-octets path (subseq body 5))
      (multiple-value-bind (forms offset) (wc:read-frames path first-end)
        (ok (null forms))
        (ok (= offset first-end)))
      (%append-octets path (vector 10))
      (multiple-value-bind (forms offset) (wc:read-frames path first-end)
        (ok (equal '((:result "ünïcode")) forms))
        (ok (= offset (%file-length path)))))))

(deftest read-frames-missing-file
  (let ((path (%temp-file "absent")))
    (multiple-value-bind (forms offset) (wc:read-frames path 7)
      (ok (null forms))
      (ok (eql 7 offset)))))

(deftest read-frames-malformed
  (let ((bad-header (%temp-file "bad-header"))
        (bad-body (%temp-file "bad-body")))
    (%write-frames bad-header '(:result 1))
    (%append-octets bad-header (babel:string-to-octets (format nil "abc~%xyz~%")
                                                       :encoding :ascii))
    (let ((c (%catch (lambda () (wc:read-frames bad-header 0)))))
      (ok (typep c 'wc:channel-error))
      (ok (and (typep c 'wc:channel-error)
               (eql (wc:channel-error-offset c)
                    (length (babel:string-to-octets
                             (format nil "~d~%~a~%" (length "(:RESULT 1)") "(:RESULT 1)")
                             :encoding :ascii))))))
    ;; a body with two forms
    (%append-octets bad-body (babel:string-to-octets (format nil "5~%1 2 3~%")
                                                     :encoding :ascii))
    (ok (typep (%catch (lambda () (wc:read-frames bad-body 0))) (quote wc:channel-error)))
    ;; *READ-EVAL* is off
    (let ((evil (%temp-file "read-eval")))
      (%append-octets evil (babel:string-to-octets (format nil "7~%#.(+ 1)~%")
                                                   :encoding :ascii))
      (ok (typep (%catch (lambda () (wc:read-frames evil 0))) (quote wc:channel-error))))))
