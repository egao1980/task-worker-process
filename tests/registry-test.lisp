(in-package #:task-worker-process/tests)

;;; 0.1.0 contract: the handler registry (src/registry.lisp). No child.

(deftest define-find-list-remove
  (let ((r (w:make-handler-registry)))
    (ok (w:handler-registry-p r))
    (ok (null (w:list-job-handlers r)))
    (let ((h (w:define-job-handler r :render "my-pkg::render"
                                   :systems '("my-system" :other-system)
                                   :timeout 90)))
      (ok (w:job-handler-p h))
      (ok (eq :render (w:job-handler-kind h)))
      (ok (equal "my-pkg::render" (w:job-handler-function h)))
      (ok (equal '("my-system" "other-system") (w:job-handler-systems h)))
      (ok (eql 90 (w:job-handler-timeout h)))
      (ok (eq h (w:find-job-handler r :render))))
    (w:define-job-handler r '("composite" 1) 'w:make-handler-registry)
    (ok (equal "TASK-WORKER-PROCESS:MAKE-HANDLER-REGISTRY"
               (w:job-handler-function (w:find-job-handler r (list "composite" 1))))
        "kinds compare with EQUAL; a symbol is stored with its package")
    (ok (null (w:job-handler-systems (w:find-job-handler r '("composite" 1)))))
    (ok (null (w:job-handler-timeout (w:find-job-handler r '("composite" 1)))))
    (ok (equal '(:render ("composite" 1)) (w:job-handler-kinds r)))
    ;; redefinition keeps the position
    (w:define-job-handler r :render "other:fn" :timeout 1/2)
    (ok (equal '(:render ("composite" 1)) (w:job-handler-kinds r)))
    (ok (equal "other:fn" (w:job-handler-function (w:find-job-handler r :render))))
    (ok (null (w:job-handler-systems (w:find-job-handler r :render))))
    (ok (eq t (w:remove-job-handler r :render)))
    (ok (null (w:remove-job-handler r :render)))
    (ok (equal '(("composite" 1)) (w:job-handler-kinds r)))
    (ok (equal 1 (length (w:list-job-handlers r))))))

(deftest unknown-kind
  (let ((r (w:make-handler-registry)))
    (ok (null (w:find-job-handler r :nope :errorp nil)))
    (let ((c (%catch (lambda () (w:find-job-handler r :nope)))))
      (ok (typep c 'w:unknown-job-kind))
      (ok (and (typep c 'w:unknown-job-kind)
               (eq :nope (w:unknown-job-kind-kind c))))
      (ok (typep c 'w:worker-error)))
    (let* ((other (w:define-job-handler r :other "a:b"))
           (got (handler-bind ((w:unknown-job-kind
                                 (lambda (c)
                                   (declare (ignore c))
                                   (use-value other))))
                  (w:find-job-handler r :nope))))
      (ok (eq other got) "USE-VALUE's value is returned"))))

(deftest invalid-handler-arguments
  (let ((r (w:make-handler-registry)))
    (dolist (bad (list "no-colon" ":name-only" "pkg:" "pkg:::x" "a b:c" "" 42
                       :keyword (make-symbol "UNINTERNED")))
      (let ((c (%catch (lambda () (w:define-job-handler r :k bad)))))
        (ok (and (typep c 'w:invalid-job-handler)
                 (eq :handler (w:worker-configuration-error-option c))
                 (equal bad (w:worker-configuration-error-value c))
                 (eq :k (w:invalid-job-handler-kind c)))
            (format nil "handler ~s is refused" bad))))
    (let ((c (%catch (lambda () (w:define-job-handler r :k "a:b" :systems "not-a-list")))))
      (ok (and (typep c 'w:invalid-job-handler)
               (eq :systems (w:worker-configuration-error-option c)))))
    (let ((c (%catch (lambda () (w:define-job-handler r :k "a:b" :systems '(1 2))))))
      (ok (and (typep c 'w:invalid-job-handler)
               (eq :systems (w:worker-configuration-error-option c)))))
    (dolist (bad '(0 -1 "10"))
      (let ((c (%catch (lambda () (w:define-job-handler r :k "a:b" :timeout bad)))))
        (ok (and (typep c 'w:invalid-job-handler)
                 (eq :timeout (w:worker-configuration-error-option c)))
            (format nil "timeout ~s is refused" bad))))
    (ok (null (w:list-job-handlers r)) "nothing refused was stored")
    ;; USE-VALUE substitutes, and the substitute is checked again
    (let ((seen '()))
      (let ((h (handler-bind ((w:invalid-job-handler
                                (lambda (c)
                                  (push (w:worker-configuration-error-value c) seen)
                                  (use-value (if (equal "bad" (w:worker-configuration-error-value c))
                                                 "still bad"
                                                 "good:one")))))
                 (w:define-job-handler r :k "bad"))))
        (ok (equal "good:one" (w:job-handler-function h)))
        (ok (equal '("bad" "still bad") (reverse seen)))))))
