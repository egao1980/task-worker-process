(in-package #:task-worker-process/child)

;;; 0.1.0 child entry point (contract).
;;;
;;; The parent writes, in a fresh job directory D:
;;;   D/request.sexp   one readable plist (FRAME-STRING syntax):
;;;                    (:job-id ID :kind KIND :payload PAYLOAD
;;;                     :handler "PKG::NAME" :systems ("sys" …))
;;;   D/boot.lisp      the forms the child command LOADs; the last one
;;;                    calls (CHILD-MAIN D)
;;; and launches the child with its stdout and stderr on D/child.log.
;;;
;;; CHILD-MAIN, in order:
;;;  1. reads D/request.sexp (*READ-EVAL* NIL, standard syntax);
;;;  2. opens D/channel for (UNSIGNED-BYTE 8) output, appending;
;;;  3. loads each of SYSTEMS with ASDF:LOAD-SYSTEM, in order;
;;;  4. reads HANDLER with *READ-EVAL* NIL and *PACKAGE* CL-USER (so the
;;;     designator names its package) and takes its FDEFINITION;
;;;  5. calls (handler PAYLOAD :report-progress RP :cancel-requested-p CP):
;;;       RP = (lambda (&key phase fraction message) …) writes a :progress
;;;            frame and returns NIL. FRACTION must be NIL or a real in
;;;            [0, 1], else RP signals TYPE-ERROR in the handler (nothing
;;;            written), which the handler may handle.
;;;       CP = (lambda () …) → T once D/cancel exists (the parent creates
;;;            it on a cancel request), else NIL.
;;;  6. writes (:result VALUE) and exits with code 0.
;;; Any SERIOUS-CONDITION escaping steps 3–6 (an ERROR, heap exhaustion,
;;; a stack exhaustion, a PRINT-NOT-READABLE result) is written as one
;;; :error frame (see channel.lisp) and the child exits with code 1. A
;;; request that cannot be read exits with code 2 and writes no frame.
;;; The child exits with UIOP:QUIT and FINISH-OUTPUT NIL, after it has
;;; finished its own output: threads a handler left running do not delay
;;; the exit. Nothing is caught that does not unwind (an abort exit from the
;;; handler, a fatal runtime error): those reach the parent as an exit code
;;; and the log.

(defun child-main (directory)
  "Run the job described in DIRECTORY (see the file header) and exit the
   process. Never returns."
  (declare (ignore directory))
  (%pending 'child-main))
