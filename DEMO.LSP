(define (fact n)
  (if (= n 0) 1 (* n (fact (- n 1)))))

(display "Factorial demo:")
(newline)

(define (print-facts n)
  (if (> n 10) (quote done)
    (begin
      (display n)
      (display "! = ")
      (display (fact n))
      (newline)
      (print-facts (+ n 1)))))
(print-facts 1)

(define (fib n)
  (define (fib-iter a b count)
    (if (= count 0) b
      (fib-iter (+ a b) a (- count 1))))
  (fib-iter 1 0 n))

(newline)
(display "Fibonacci demo:")
(newline)

(define (print-fibs n max)
  (if (> n max) (quote done)
    (begin
      (display "fib(")
      (display n)
      (display ") = ")
      (display (fib n))
      (newline)
      (print-fibs (+ n 1) max))))
(print-fibs 0 10)

(newline)
(display "Blinking LED 5 times...")
(newline)

(define (blink n)
  (if (= n 0) (quote done)
    (begin
      (gpio-write 27 1)
      (delay 250)
      (gpio-write 27 0)
      (delay 250)
      (blink (- n 1)))))
(blink 5)

(display "Done!")
(newline)
