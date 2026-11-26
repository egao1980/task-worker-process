(defpackage #:task-worker-process/tests
  (:use #:cl #:rove)
  (:local-nicknames (#:w #:task-worker-process)
                    (#:wc #:task-worker-process/child)
                    (#:q #:task-protocol)))

(in-package #:task-worker-process/tests)
