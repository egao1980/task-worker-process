(in-package #:task-worker-process)

;;; 0.1.0 job handler registry (classes given, operations contract).
;;;
;;; A registry maps a job KIND (any object, compared with EQUAL, as
;;; task-protocol compares kinds) to a JOB-HANDLER: the handler designator,
;;; the systems the child loads before calling it, and the kind's timeout.
;;; It is a plain lookup table, nothing more: no precedence, no defaults
;;; derived from other entries.
;;;
;;; A handler is a plain function, loaded in the child only:
;;;
;;;   (handler payload &key report-progress cancel-requested-p) → result
;;;
;;; PAYLOAD is the job's payload; REPORT-PROGRESS is a function
;;; (&key phase fraction message) and CANCEL-REQUESTED-P a function of no
;;; arguments (see src/child/main.lisp). RESULT must cross the channel
;;; (src/child/channel.lisp: readable under standard syntax, no hash
;;; tables). The parent never loads the handler's systems.
;;;
;;; Designators. HANDLER is
;;;   - a symbol with a home package (not a keyword): stored as PRIN1 prints
;;;     it under standard syntax with *PACKAGE* KEYWORD ("PKG:NAME" for an
;;;     external symbol, "PKG::NAME" otherwise); or
;;;   - a string "PKG:NAME" or "PKG::NAME" in reader syntax: one or two
;;;     colons with a non-empty package part before and a non-empty name
;;;     part after, no whitespace. It is stored as given and read in the
;;;     child after SYSTEMS are loaded, so its package need not exist in
;;;     the parent.
;;; SYSTEMS is a list of strings or symbols (ASDF system designators),
;;; stored as downcased strings for symbols, as given for strings; default
;;; NIL. TIMEOUT is NIL (none) or a positive real, seconds.
;;;
;;; Validation. Each refused argument signals INVALID-JOB-HANDLER (OPTION
;;; :HANDLER, :SYSTEMS or :TIMEOUT, VALUE the argument, KIND) with a
;;; USE-VALUE restart taking a replacement for that argument, which is
;;; checked again.

(defclass job-handler ()
  ((kind :initarg :kind :reader job-handler-kind)
   (function :initarg :function :reader job-handler-function
             :documentation "The designator string, \"PKG::NAME\" or \"PKG:NAME\".")
   (systems :initarg :systems :reader job-handler-systems :initform '()
            :documentation "Strings, loaded in order in the child.")
   (timeout :initarg :timeout :reader job-handler-timeout :initform nil
            :documentation "NIL or seconds, counted from the child's launch
             (Lisp start-up and system loading included)."))
  (:documentation "How the child runs one job kind."))

(defun job-handler-p (x)
  (typep x 'job-handler))

(defmethod print-object ((handler job-handler) stream)
  (print-unreadable-object (handler stream :type t)
    (format stream "~s ~a" (job-handler-kind handler)
            (job-handler-function handler))))

(defclass handler-registry ()
  ((handlers :initform '() :accessor %registry-handlers
             :documentation "JOB-HANDLERs in definition order.")
   (lock :initform (bt:make-recursive-lock "task-worker-process registry")
         :reader %registry-lock))
  (:documentation "Kind → JOB-HANDLER. Thread-safe: the supervisor's job
   threads read it while the application may redefine entries."))

(defun handler-registry-p (x)
  (typep x 'handler-registry))

;;; Validation helpers (shared with supervisor.lisp)

(defun %read-new-value ()
  "The :INTERACTIVE function of the USE-VALUE restarts: one evaluated form."
  (format *query-io* "~&Value (evaluated): ")
  (force-output *query-io*)
  (list (eval (read *query-io*))))

(defun %validated (value valid-p signal)
  "VALUE once VALID-P accepts it. Otherwise (FUNCALL SIGNAL VALUE), which
   signals, inside a USE-VALUE restart whose value is checked again."
  (loop until (funcall valid-p value)
        do (setf value
                 (restart-case (funcall signal value)
                   (use-value (new)
                     :report "Use another value (it is checked again)."
                     :interactive %read-new-value
                     new))))
  value)

(defun %designator-string-p (x)
  "\"PKG:NAME\" or \"PKG::NAME\": a non-empty package part, one or two
   colons, a non-empty name part with no colon, no whitespace."
  (and (stringp x)
       (notany (lambda (c)
                 (member c '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed)))
               x)
       (let ((colon (position #\: x)))
         (and colon (plusp colon)
              (let ((name-start (if (and (< (1+ colon) (length x))
                                         (char= #\: (char x (1+ colon))))
                                    (+ colon 2)
                                    (1+ colon))))
                (and (< name-start (length x))
                     (not (find #\: x :start name-start))))))))

(defun %designator-symbol-p (x)
  (and x (symbolp x) (symbol-package x) (not (keywordp x))))

(defun %handler-designator-p (x)
  (or (%designator-string-p x) (%designator-symbol-p x)))

(defun %handler-designator-string (x)
  (if (stringp x)
      x
      (with-standard-io-syntax
        (let ((*package* (find-package '#:keyword)))
          (prin1-to-string x)))))

(defun %proper-list-p (x)
  (and (listp x) (null (cdr (last x)))))

(defun %systems-p (x)
  (and (%proper-list-p x)
       (every (lambda (s) (or (stringp s) (and s (symbolp s)))) x)))

(defun %timeout-p (x)
  (or (null x) (and (realp x) (plusp x))))

;;; Operations

(defun make-handler-registry ()
  "A fresh, empty HANDLER-REGISTRY."
  (make-instance 'handler-registry))

(defun define-job-handler (registry kind handler &key systems timeout)
  "Define or redefine KIND's handler in REGISTRY (see the file header for
   HANDLER, SYSTEMS, TIMEOUT and their validation). A redefinition
   replaces the entry in place (its position in LIST-JOB-HANDLERS stays).
   → the JOB-HANDLER."
  (check-type registry handler-registry)
  (flet ((check (option value valid-p)
           (%validated value valid-p
                       (lambda (v)
                         (error 'invalid-job-handler :kind kind :option option
                                                     :value v)))))
    (let* ((handler (check :handler handler #'%handler-designator-p))
           (systems (check :systems systems #'%systems-p))
           (timeout (check :timeout timeout #'%timeout-p))
           (entry (make-instance 'job-handler
                                 :kind kind
                                 :function (%handler-designator-string handler)
                                 :systems (mapcar (lambda (s)
                                                    (if (stringp s)
                                                        s
                                                        (string-downcase (symbol-name s))))
                                                  systems)
                                 :timeout timeout)))
      (bt:with-recursive-lock-held ((%registry-lock registry))
        (let ((cell (member kind (%registry-handlers registry)
                            :key #'job-handler-kind :test #'equal)))
          (if cell
              (setf (car cell) entry)
              (setf (%registry-handlers registry)
                    (append (%registry-handlers registry) (list entry))))))
      entry)))

(defun find-job-handler (registry kind &key (errorp t))
  "KIND's JOB-HANDLER in REGISTRY. An unknown KIND → NIL when ERRORP is
   NIL, else UNKNOWN-JOB-KIND with a USE-VALUE restart whose value (a
   JOB-HANDLER or NIL) FIND-JOB-HANDLER returns."
  (check-type registry handler-registry)
  (let ((handler (bt:with-recursive-lock-held ((%registry-lock registry))
                   (find kind (%registry-handlers registry)
                         :key #'job-handler-kind :test #'equal))))
    (cond (handler)
          ((not errorp) nil)
          (t
           ;; signalled outside the lock
           (restart-case (error 'unknown-job-kind :kind kind)
             (use-value (value)
               :report "Use another job handler (or NIL)."
               :interactive %read-new-value
               value))))))

(defun remove-job-handler (registry kind)
  "Remove KIND's entry. → T when there was one, else NIL."
  (check-type registry handler-registry)
  (bt:with-recursive-lock-held ((%registry-lock registry))
    (let ((handlers (%registry-handlers registry)))
      (when (find kind handlers :key #'job-handler-kind :test #'equal)
        (setf (%registry-handlers registry)
              (remove kind handlers :key #'job-handler-kind :test #'equal))
        t))))

(defun list-job-handlers (registry)
  "REGISTRY's JOB-HANDLERs in definition order (a fresh list)."
  (check-type registry handler-registry)
  (bt:with-recursive-lock-held ((%registry-lock registry))
    (copy-list (%registry-handlers registry))))

(defun job-handler-kinds (registry)
  "The kinds REGISTRY has handlers for, in definition order (a fresh
   list). The supervisor claims only these kinds."
  (check-type registry handler-registry)
  (bt:with-recursive-lock-held ((%registry-lock registry))
    (mapcar #'job-handler-kind (%registry-handlers registry))))
