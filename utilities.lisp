;;;; Misc string and vector handling for docutils
;;;; Copyright (C) 2005 John A.R. Williams <J.A.R.Williams@jarw.org.uk>
;;;; Released under the GNU General Public License (GPL)
;;;; See <http://www.gnu.org/copyleft/gpl.html> for license details
;;;;
;;;; A document node has format ((tagname attributes) content) where
;;;; tagname is a keyword symbol, attributes a p-list
;;;; and content a list of nodes or content atoms
;;;; $Id: utilities.lisp,v 1.12 2007/07/26 08:56:35 willijar Exp willijar $

(in-package :docutils.utilities)

(defvar *tab-size* 8 "The amount of space that a tab is equivalent to")

(defparameter +wsp+ '(#\space #\tab #\return #\newline #\Vt #\Page)
  "White space characters")

(deftype wsp() '(member #\space #\tab #\return #\newline #\Vt #\Page))

(declaim (inline wsp-char-p line-blank-p))
(defun wsp-char-p(c) (typep c 'wsp))

(declaim (inline line-blank-p line-length))
(defun line-blank-p(line)
  (declare (string line))
  (every #'wsp-char-p line))

(defun line-length(line)
  "Return length of line excluding trailing whitespace"
  (1+ (position-if-not #'wsp-char-p line :from-end t)))

(defun indent-level(line &key (tab-size *tab-size*))
  "Returns the indentation level of the line, including tabs as expanded"
  (declare (type simple-string line)
	   (fixnum tab-size))
  (let((l 0))
    (declare (fixnum l))
    (loop for c across (the simple-string line)
	 while (wsp-char-p c)
	 do (incf l (if (char= c #\tab) tab-size 1)))
    l))

(defun nsubvector(array start &optional (end (length array)))
  "Returns a displaced array on array of element from start to end (default
length array)"
  (if (and (= 0 start) (= end (length array)))
      array
      (multiple-value-bind(displaced-to index-offset)
          (array-displacement array)
        (if displaced-to
            (make-array (- (or end (length array)) start)
                        :element-type (array-element-type array)
                        :displaced-to displaced-to
                        :displaced-index-offset (+ start index-offset))
            (make-array (- (or end (length array)) start)
                        :element-type (array-element-type array)
                        :displaced-to array
                        :displaced-index-offset start)))))

(defmacro do-vector((element vector &key (counter (gensym)) (start 0) end)
		    &body body)
  "Iterate over the elements of a vector. Aon each iteration element
is bound to the current element and counter to the index of this
element. start and end may be used to specify the range of indexes to
be iterated over."
  (let ((gvector (gensym))
	(gend (gensym)))
    `(let* ((,gvector ,vector)
	    (,gend ,(or end `(length ,gvector))))
      (do*((,counter ,start (1+ ,counter)))
	  ((>= ,counter ,gend))
	(let ((,element (aref ,gvector ,counter)))
	  ,@body)))))

(declaim (inline rstrip strip))
(defun rstrip(string)
  "Remove trailing white space from string"
  (string-right-trim +wsp+ string))
(defun strip(string)
  "Remove prefixing and trailing white space from string"
  (string-trim +wsp+ string))
(defun lstrip(string)
  (string-left-trim +wsp+ string))

(defun lines-left-trim(lines length &key (start 0) (end (length lines)))
  "Trim `length` characters off the beginning of each line,
from index `start` to `end`.  No whitespace-checking is done on the
trimmed text."
  (map 'vector #'(lambda(s) (subseq s (min length (length s))))
       (nsubvector lines start end)))

(defun escape2null(string &key (start 0) (end (length string)))
  "Return a string with escape-backslashes converted to nulls."
  (with-output-to-string(os)
    (with-input-from-string(is string :start start :end end)
      (do((c (read-char is nil) (read-char is nil)))
         ((not c))
        (cond((and (eq c #\\) (eq (peek-char nil is nil) #\\))
              (read-char is nil)
              (write-char #\null os))
             (t (write-char c os)))))))

(defun unescape(text &key restore-backslashes (start 0) end)
  "Return a string with nulls removed or restored to backslashes.
    Backslash-escaped spaces are also removed."
  (with-output-to-string(os)
    (with-input-from-string(is text :start start :end end)
      #+debug(when  (< (or end (length text)) start)
               (break "start=~S end=~D length=~D" end (length text)))
      (do((c (read-char is nil) (read-char is nil)))
         ((not c))
        (cond((eq c #\null)
              (if restore-backslashes
                  (write-char #\\ os)
                  (let ((next (peek-char nil is nil)))
                    (when (wsp-char-p next) (read-char is nil)))))
             (t (write-char c os)))))))

(defun split-lines(string)
  "Return a vector of lines split from string"
  (let ((lines (split-sequence #\newline string)))
    (make-array (length lines)
                :element-type 'string
                :initial-contents lines)))

(defun indented-block(lines &key
                      (start 0)  until-blank (strip-indent t)
                      block-indent  first-indent)
  "Extract and return a vector of indented lines of text.

Collect all lines with indentation, determine the minimum
indentation, remove the minimum indentation from all indented lines
unless STRIP-INDENT is false, and return them. All lines up to but
not including the first unindented line will be returned in a new vector.

Keyword arguments:
 START: The index of the first line to examine.
 UNTIL-BLANK: Stop collecting at the first blank line if true.
 STRIP-INDENT: Strip common leading indent if true (default).
 BLOCK-INDENT: The indent of the entire block, if known.
 FIRST-INDENT: The indent of the first line, if known.

Returns values:
 a new vector of the indented lines with minimum indent removed
 the amount of the indent
 a boolean: did the indented block finish with a blank line or EOF?"
  (let* ((indent block-indent)
	 (first-indent (or first-indent block-indent))
	 (end (if first-indent (1+ start) start))
	 (last (length lines))
	 (blank-finish t))
    (loop
       (unless (< end last) (setf blank-finish t) (return))
       (let* ((line (aref lines end))
	      (line-indent (indent-level line)))
	 (cond
	   ((line-blank-p line)
	    (when until-blank (setf blank-finish t) (return)))
	   ((or (= line-indent 0)
		(and block-indent (< line-indent block-indent)))
	    ;;Line not indented or insufficiently indented.
	    ;;Block finished properly if the last indented line blank:
	    (setf blank-finish (and (> end start)
				    (line-blank-p (aref lines (1- end)))))
	    (return))
	   ((not block-indent)
	    (setf indent
		  (if indent
		      (min indent line-indent)
		      line-indent)))))
       (incf end))
    (let ((block (subseq lines start end)))
      (when (> (length block) 0)
	(when first-indent
	  (setf (aref block 0)
		(subseq (aref block 0)
			(min first-indent (length (aref block 0))))))
	(when (and indent strip-indent)
	  (dotimes(idx (length block))
	    (unless (and (= idx 0) first-indent)
	      (let ((s (aref block idx)))
		(setf (aref block idx) (subseq s (min indent (length s)))))))))
      (values block (or indent 0) blank-finish))))

(defun whitespace-normalise-name(name)
  "Return and whitespace-normalized name."
  (let ((last-wsp-p t))
    (string-trim
     +wsp+
     (with-output-to-string(os)
       (loop for c across name
             do (setf last-wsp-p
                      (cond
                        ((wsp-char-p c)
                         (unless last-wsp-p (write-char #\space os))
                         t)
                        (t (write-char c os) nil))))))))

(defun normalise-name(name)
  (let ((last-wsp-p t))
    (string-trim
     +wsp+
     (with-output-to-string(os)
       (loop for c across name
             do (setf last-wsp-p
                      (cond
                        ((wsp-char-p c)
                         (unless last-wsp-p (write-char #\space os))
                         t)
                        (t (write-char (char-downcase c) os) nil))))))))

(defun make-id(string)
  "Make an ID from string that meets requirements of CSS and html 4.01"
  (let ((start t)
        (last--p nil))
    (with-output-to-string(os)
      (loop
       :for c :across string
       :do
       (cond
         (start
          (when (alpha-char-p c)
            (setf start nil)
            (write-char c os)))
          ((alphanumericp c)
           (write-char c os)
           (setf last--p nil))
          ((not last--p)
           (write-char #\- os)
           (setf last--p t)))))))

(defgeneric read-lines(entity)
  (:documentation "Read and return a vector of lines from an entity
for subsequent parsing"))

(defmethod read-lines((is stream))
  (let ((lines nil))
    (do ((line (read-line is nil) (read-line is nil)))
        ((not line))
      (push line lines))
    (make-array (length lines)
                :element-type 'string :initial-contents
                (nreverse lines))))

(defmethod read-lines((source pathname))
  (with-open-file(is source :direction :input)
    (read-lines is)))

(defmethod read-lines((source string))
  (split-lines source))

(defmethod read-lines((source vector))
  source)