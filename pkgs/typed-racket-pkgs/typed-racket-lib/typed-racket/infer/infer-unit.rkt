#lang racket/unit

;; This is the main file that defines local type inference in TR
;;
;; The algorithm is based on
;;   "Local Type Inference" by Pierce and Turner
;;   ACM TOPLAS, Vol. 22, No. 1, January 2000.
;;

(require "../utils/utils.rkt"
         (except-in
          (combine-in
           (utils tc-utils)
           (rep free-variance type-rep filter-rep object-rep rep-utils)
           (types utils abbrev numeric-tower union subtype resolve
                  substitute generalize)
           (env index-env tvar-env))
          make-env -> ->* one-of/c)
         "constraint-structs.rkt"
         "signatures.rkt" "fail.rkt"
         racket/match
         mzlib/etc
         (contract-req)
         unstable/sequence unstable/list unstable/hash
         racket/list)

(import dmap^ constraints^ promote-demote^)
(export infer^)

;; For more data definitions, see "constraint-structs.rkt"
;;
;; A Seen is a set represented by a list of Pair<Seq, Seq>
(define (empty-set) '())

(define current-seen (make-parameter (empty-set)))

;; Type Type -> Pair<Seq, Seq>
;; construct a pair for the set of seen type pairs
(define (seen-before s t)
  (cons (Type-seq s) (Type-seq t)))

;; Type Type Seen -> Seen
;; Add the type pair to the set of seen type pairs
(define/cond-contract (remember s t A)
  ((or/c AnyValues? Values/c ValuesDots?) (or/c AnyValues? Values/c ValuesDots?)
   (listof (cons/c exact-nonnegative-integer?
                   exact-nonnegative-integer?))
   . -> .
   (listof (cons/c exact-nonnegative-integer?
                   exact-nonnegative-integer?)))
 (cons (seen-before s t) A))

;; Type Type -> Boolean
;; Check if a given type pair have been seen before
(define/cond-contract (seen? s t cs)
  ((or/c AnyValues? Values/c ValuesDots?) (or/c AnyValues? Values/c ValuesDots?)
   (listof (cons/c exact-nonnegative-integer?
                   exact-nonnegative-integer?))
   . -> . any/c)
 (member (seen-before s t) cs))

;; (CMap DMap -> Pair<CMap, DMap>) CSet -> CSet
;; Map a function over a constraint set
(define (map/cset f cset)
  (% make-cset (for/list/fail ([(cmap dmap) (in-pairs (cset-maps cset))])
                 (f cmap dmap))))

;; Symbol DCon -> DMap
;; Construct a dmap containing only a single mapping
(define (singleton-dmap dbound dcon)
  (make-dmap (make-immutable-hash (list (cons dbound dcon)))))

;; Hash<K, V> Listof<K> -> Hash<K, V>
;; Remove all provided keys from the hash table
(define (hash-remove* hash keys)
  (for/fold ([h hash]) ([k (in-list keys)]) (hash-remove h k)))

(define (mover cset dbound vars f)
  (map/cset
   (lambda (cmap dmap)
     (% cons
        (hash-remove* cmap (cons dbound vars))
        (dmap-meet
         (singleton-dmap
          dbound
          (f cmap dmap))
         (make-dmap (hash-remove (dmap-map dmap) dbound)))))
   cset))

;; dbound : index variable
;; vars : listof[type variable] - temporary variables
;; cset : the constraints being manipulated
;; takes the constraints on vars and creates a dmap entry constraining dbound to be |vars|
;; with the constraints that cset places on vars
(define/cond-contract (move-vars-to-dmap cset dbound vars)
  (cset? symbol? (listof symbol?) . -> . cset?)
  (mover cset dbound vars
         (λ (cmap dmap)
           (make-dcon (for/list ([v (in-list vars)])
                        (hash-ref cmap v
                                  (λ () (int-err "No constraint for new var ~a" v))))
                      #f))))

;; dbound : index variable
;; cset : the constraints being manipulated
;;
(define/cond-contract (move-rest-to-dmap cset dbound #:exact [exact? #f])
  ((cset? symbol?) (#:exact boolean?) . ->* . cset?)
  (mover cset dbound null
         (λ (cmap dmap)
           ((if exact? make-dcon-exact make-dcon)
            null
            (hash-ref cmap dbound
                      (λ () (int-err "No constraint for bound ~a" dbound)))))))

;; cset : the constraints being manipulated
;; var : index variable being inferred
;; dbound : constraining index variable
;;
(define/cond-contract (move-dotted-rest-to-dmap cset var dbound)
  (cset? symbol? symbol? . -> . cset?)
  (mover cset var null
         (λ (cmap dmap)
           (make-dcon-dotted
            null
            (hash-ref cmap var
                      (λ () (int-err "No constraint for bound ~a" var)))
            dbound))))

;; This one's weird, because the way we set it up, the rest is already in the dmap.
;; This is because we create all the vars, then recall cgen/arr with the new vars
;; in place, and the "simple" case will then call move-rest-to-dmap.  This means
;; we need to extract that result from the dmap and merge it with the fixed vars
;; we now handled.  So I've extended the mover to give access to the dmap, which we use here.
(define/cond-contract (move-vars+rest-to-dmap cset dbound vars #:exact [exact? #f])
  ((cset? symbol? (listof symbol?)) (#:exact boolean?) . ->* . cset?)
  (mover cset dbound vars
         (λ (cmap dmap)
           ((if exact? make-dcon-exact make-dcon)
            (for/list ([v (in-list vars)])
              (hash-ref cmap v (λ () (int-err "No constraint for new var ~a" v))))
            (match (hash-ref (dmap-map dmap) dbound
                             (λ () (int-err "No constraint for bound ~a" dbound)))
              [(dcon null rest) rest]
              [(dcon-exact null rest) rest]
              [_ (int-err "did not get a rest-only dcon when moving to the dmap")])))))


;; Maps dotted vars (combined with dotted types, to ensure global uniqueness)
;; to "fresh" symbols.
;; That way, we can share the same "fresh" variables between the elements of a
;; cset if they're talking about the same dotted variable.
;; This makes it possible to reduce the size of the csets, since we can detect
;; identical elements that would otherwise differ only by these fresh vars.
;; The domain of this map is pairs (var . dotted-type).
;; The range is this map is a list of symbols generated on demand, as we need
;; more dots.
(define dotted-var-store (make-hash))
;; Take (generate as needed) n symbols that correspond to variable var used in
;; the context of type t.
(define (var-store-take var t n)
  (let* ([key (cons var t)]
         [res (hash-ref dotted-var-store key '())])
    (if (>= (length res) n)
        ;; there are enough symbols already, take n
        (take res n)
        ;; we need to generate more
        (let* ([new (build-list (- n (length res))
                                (lambda (x) (gensym var)))]
               [all (append res new)])
          (hash-set! dotted-var-store key all)
          all))))

(define/cond-contract (cgen/filter V X Y s t)
  ((listof symbol?) (listof symbol?) (listof symbol?) Filter? Filter? . -> . (or/c #f cset?))
  (match* (s t)
    [(e e) (empty-cset X Y)]
    [(e (Top:)) (empty-cset X Y)]
    ;; FIXME - is there something to be said about the logical ones?
    [((TypeFilter: s p i) (TypeFilter: t p i)) (cgen/inv V X Y s t)]
    [((NotTypeFilter: s p i) (NotTypeFilter: t p i)) (cgen/inv V X Y s t)]
    [(_ _) #f]))

;; s and t must be *latent* filter sets
(define/cond-contract (cgen/filter-set V X Y s t)
  ((listof symbol?) (listof symbol?) (listof symbol?) FilterSet? FilterSet? . -> . (or/c #f cset?))
  (match* (s t)
    [(e e) (empty-cset X Y)]
    [((FilterSet: s+ s-) (FilterSet: t+ t-))
     (% cset-meet (cgen/filter V X Y s+ t+) (cgen/filter V X Y s- t-))]
    [(_ _) #f]))

(define/cond-contract (cgen/object V X Y s t)
  ((listof symbol?) (listof symbol?) (listof symbol?) Object? Object? . -> . (or/c #f cset?))
  (match* (s t)
    [(e e) (empty-cset X Y)]
    [(e (Empty:)) (empty-cset X Y)]
    ;; FIXME - do something here
    [(_ _) #f]))

(define/cond-contract (cgen/arr V X Y s-arr t-arr)
  ((listof symbol?) (listof symbol?) (listof symbol?) arr? arr? . -> . (or/c #f cset?))
  (define (cg S T) (cgen V X Y S T))
  (match*/early (s-arr t-arr)
    ;; the simplest case - no rests, drests, keywords
    [((arr: ss s #f #f '())
      (arr: ts t #f #f '()))
     (% cset-meet
        ;; contravariant
        (cgen/list V X Y ts ss)
        ;; covariant
        (cg s t))]
    ;; just a rest arg, no drest, no keywords
    [((arr: ss s s-rest #f '())
      (arr: ts t t-rest #f '()))
     (let ([arg-mapping
            (cond
              ;; both rest args are present, so make them the same length
              [(and s-rest t-rest)
               (cgen/list V X Y
                          (cons t-rest (extend ss ts t-rest))
                          (cons s-rest (extend ts ss s-rest)))]
              ;; no rest arg on the right, so just pad the left and forget the rest arg
              [(and s-rest (not t-rest) (<= (length ss) (length ts)))
               (cgen/list V X Y ts (extend ts ss s-rest))]
              ;; no rest arg on the left, or wrong number = fail
              [else #f])]
           [ret-mapping (cg s t)])
       (% cset-meet arg-mapping ret-mapping))]
    ;; dotted on the left, nothing on the right
    [((arr: ss s #f (cons dty dbound) '())
      (arr: ts t #f #f                '()))
     #:return-unless (memq dbound Y)
     #f
     #:return-unless (<= (length ss) (length ts))
     #f
     (let* ([vars      (var-store-take dbound dty (- (length ts) (length ss)))]
            [new-tys   (for/list ([var (in-list vars)])
                         (substitute (make-F var) dbound dty))]
            [new-s-arr (make-arr (append ss new-tys) s #f #f null)]
            [new-cset  (cgen/arr V (append vars X) Y new-s-arr t-arr)])
       (% move-vars-to-dmap new-cset dbound vars))]
    ;; dotted on the right, nothing on the left
    [((arr: ss s #f #f                '())
      (arr: ts t #f (cons dty dbound) '()))
     #:return-unless (memq dbound Y)
     #f
     #:return-unless (<= (length ts) (length ss))
     #f
     (let* ([vars     (var-store-take dbound dty (- (length ss) (length ts)))]
            [new-tys  (for/list ([var (in-list vars)])
                        (substitute (make-F var) dbound dty))]
            [new-t-arr (make-arr (append ts new-tys) t #f #f null)]
            [new-cset (cgen/arr V (append vars X) Y s-arr new-t-arr)])
       (% move-vars-to-dmap new-cset dbound vars))]
    ;; this case is just for constrainting other variables, not dbound
    [((arr: ss s #f (cons s-dty dbound) '())
      (arr: ts t #f (cons t-dty dbound) '()))
     #:return-unless (= (length ss) (length ts))
     #f
     ;; If we want to infer the dotted bound, then why is it in both types?
     #:return-when (memq dbound Y)
     #f
     (let* ([arg-mapping (cgen/list V X Y ts ss)]
            [darg-mapping (cgen V X Y t-dty s-dty)]
            [ret-mapping (cg s t)])
       (% cset-meet arg-mapping darg-mapping ret-mapping))]
    ;; bounds are different
    [((arr: ss s #f (cons s-dty (? (λ (db) (memq db Y)) dbound))  '())
      (arr: ts t #f (cons t-dty dbound*) '()))
     #:return-unless (= (length ss) (length ts)) #f
     #:return-when (memq dbound* Y) #f
     (let* ([arg-mapping (cgen/list V X Y ts ss)]
            ;; just add dbound as something that can be constrained
            [darg-mapping (% move-dotted-rest-to-dmap (cgen V (cons dbound X) Y t-dty s-dty) dbound dbound*)]
            [ret-mapping (cg s t)])
       (% cset-meet arg-mapping darg-mapping ret-mapping))]
    [((arr: ss s #f (cons s-dty dbound)  '())
      (arr: ts t #f (cons t-dty (? (λ (db) (memq db Y)) dbound*)) '()))
     #:return-unless (= (length ss) (length ts)) #f
     (let* ([arg-mapping (cgen/list V X Y ts ss)]
            ;; just add dbound as something that can be constrained
            [darg-mapping (% move-dotted-rest-to-dmap (cgen V (cons dbound* X) Y t-dty s-dty) dbound* dbound)]
            [ret-mapping (cg s t)])
       (% cset-meet arg-mapping darg-mapping ret-mapping))]
    ;; * <: ...
    [((arr: ss s s-rest #f                  '())
      (arr: ts t #f     (cons t-dty dbound) '()))
     #:return-unless (memq dbound Y)
     #f
     (if (<= (length ss) (length ts))
         ;; the simple case
         (let* ([arg-mapping (cgen/list V X Y ts (extend ts ss s-rest))]
                [darg-mapping (% move-rest-to-dmap
                                 (cgen V (cons dbound X) Y t-dty s-rest) dbound)]
                [ret-mapping (cg s t)])
           (% cset-meet arg-mapping darg-mapping ret-mapping))
         ;; the hard case
         (let* ([vars     (var-store-take dbound t-dty (- (length ss) (length ts)))]
                [new-tys  (for/list ([var (in-list vars)])
                            (substitute (make-F var) dbound t-dty))]
                [new-t-arr (make-arr (append ts new-tys) t #f (cons t-dty dbound) null)]
                [new-cset (cgen/arr V (append vars X) Y s-arr new-t-arr)])
           (% move-vars+rest-to-dmap new-cset dbound vars)))]
    ;; If dotted <: starred is correct, add it below.  Not sure it is.
    [((arr: ss s #f     (cons s-dty dbound) '())
      (arr: ts t t-rest #f                  '()))
     #:return-unless (memq dbound Y)
     #f
     (cond [(< (length ss) (length ts))
            ;; the hard case
            (let* ([vars     (var-store-take dbound s-dty (- (length ts) (length ss)))]
                   [new-tys  (for/list ([var (in-list vars)])
                               (substitute (make-F var) dbound s-dty))]
                   [new-s-arr (make-arr (append ss new-tys) s #f (cons s-dty dbound) null)]
                   [new-cset (cgen/arr V (append vars X) Y new-s-arr t-arr)])
              (and new-cset vars
                   (move-vars+rest-to-dmap new-cset dbound vars #:exact #t)))]
           [(= (length ss) (length ts))
            ;; the simple case
            (let* ([arg-mapping (cgen/list V X Y (extend ss ts t-rest) ss)]
                   [rest-mapping (cgen V (cons dbound X) Y t-rest s-dty)]
                   [darg-mapping (and rest-mapping 
                                      (move-rest-to-dmap
                                       rest-mapping dbound #:exact #t))]
                   [ret-mapping (cg s t)])
              (% cset-meet arg-mapping darg-mapping ret-mapping))]
           [else #f])]
    [(_ _) #f]))

(define/cond-contract (cgen/flds V X Y flds-s flds-t)
  ((listof symbol?) (listof symbol?) (listof symbol?) (listof fld?) (listof fld?)  
   . -> . (or/c #f cset?))
  (% cset-meet*
   (for/list/fail ([s (in-list flds-s)] [t (in-list flds-t)])
     (match* (s t)
       ;; mutable - invariant
       [((fld: s _ #t) (fld: t _ #t)) (cgen/inv V X Y s t)]
       ;; immutable - covariant
       [((fld: s _ #f) (fld: t _ #f)) (cgen V X Y s t)]))))

(define (cgen/inv V X Y s t)
  (% cset-meet (cgen V X Y s t) (cgen V X Y t s)))


;; V : a set of variables not to mention in the constraints
;; X : the set of type variables to be constrained
;; Y : the set of index variables to be constrained
;; S : a type to be the subtype of T
;; T : a type
;; produces a cset which determines a substitution that makes S a subtype of T
;; implements the V |-_X S <: T => C judgment from Pierce+Turner, extended with
;; the index variables from the TOPLAS paper
(define/cond-contract (cgen V X Y S T)
  ((listof symbol?) (listof symbol?) (listof symbol?)
   (or/c Values/c ValuesDots? AnyValues?) (or/c Values/c ValuesDots? AnyValues?)
   . -> . (or/c #F cset?))
  ;; useful quick loop
  (define/cond-contract (cg S T)
   (Type/c Type/c . -> . (or/c #f cset?))
   (cgen V X Y S T))
  (define/cond-contract (cg/inv S T)
   (Type/c Type/c . -> . (or/c #f cset?))
   (cgen/inv V X Y S T))
  ;; this places no constraints on any variables in X
  (define empty (empty-cset X Y))
  ;; this constrains just x (which is a single var)
  (define (singleton S x T)
    (insert empty x S T))
  ;; FIXME -- figure out how to use parameters less here
  ;;          subtyping doesn't need to use it quite as much
  (define cs (current-seen))
  ;; if we've been around this loop before, we're done (for rec types)
  (if (seen? S T cs)
      empty
      (parameterize (;; remember S and T, and obtain everything we've seen from the context
                     ;; we can't make this an argument since we may call back and forth with
                     ;; subtyping, for example
                     [current-seen (remember S T cs)])
        (match*/early (S T)
          ;; if they're equal, no constraints are necessary (CG-Refl)
          [(a b) #:when (type-equal? a b) empty]
          ;; CG-Top
          [(_ (Univ:)) empty]
          [(_ (AnyValues:)) empty]

          ;; check all non Type/c first so that calling subtype is safe

          ;; check each element
          [((Result: s f-s o-s)
            (Result: t f-t o-t))
           (% cset-meet (cg s t)
                        (cgen/filter-set V X Y f-s f-t)
                        (cgen/object V X Y o-s o-t))]

          ;; values are covariant
          [((Values: ss) (Values: ts))
           #:return-unless (= (length ss) (length ts))
           #f
           (cgen/list V X Y ss ts)]

          ;; this constrains `dbound' to be |ts| - |ss|
          [((ValuesDots: ss s-dty dbound) (Values: ts))
           #:return-unless (>= (length ts) (length ss)) #f
           #:return-unless (memq dbound Y) #f

           (let* ([vars     (var-store-take dbound s-dty (- (length ts) (length ss)))]
                  ;; new-tys are dummy plain type variables, 
                  ;; standing in for the elements of dbound that need to be generated
                  [new-tys  (for/list ([var (in-list vars)])
                              ;; must be a Result since we are matching these against
                              ;; the contents of the `Values`, which are Results
                              (-result (substitute (make-F var) dbound s-dty)))]
                  ;; generate constraints on the prefixes, and on the dummy types
                  [new-cset (cgen/list V (append vars X) Y (append ss new-tys) ts)])
             ;; now take all the dummy types, and use them to constrain dbound appropriately
             (% move-vars-to-dmap new-cset dbound vars))]

          ;; like the case above, but constrains `dbound' to be |ss| - |ts|
          [((Values: ss) (ValuesDots: ts t-dty dbound))
           #:return-unless (>= (length ss) (length ts)) #f
           #:return-unless (memq dbound Y) #f

           ;; see comments for last case, this case swaps `s` and `t` order
           (let* ([vars     (var-store-take dbound t-dty (- (length ss) (length ts)))]
                  [new-tys  (for/list ([var (in-list vars)])
                              (-result (substitute (make-F var) dbound t-dty)))]
                  [new-cset (cgen/list V (append vars X) Y ss (append ts new-tys))])
             (move-vars-to-dmap new-cset dbound vars))]

          ;; identical bounds - just unify pairwise
          [((ValuesDots: ss s-dty dbound) (ValuesDots: ts t-dty dbound))
           #:return-when (memq dbound Y) #f
           (cgen/list V X Y (cons s-dty ss) (cons t-dty ts))]
          [((ValuesDots: ss s-dty (? (λ (db) (memq db Y)) s-dbound))
            (ValuesDots: ts t-dty t-dbound))
           ;; What should we do if both are in Y?
           #:return-when (memq t-dbound Y) #f
           (% cset-meet
              (cgen/list V X Y ss ts)
              (% move-dotted-rest-to-dmap (cgen V (cons s-dbound X) Y s-dty t-dty) s-dbound t-dbound))]
          [((ValuesDots: ss s-dty s-dbound)
            (ValuesDots: ts t-dty (? (λ (db) (memq db Y)) t-dbound)))
           ;; s-dbound can't be in Y, due to previous rule
           (% cset-meet
              (cgen/list V X Y ss ts)
              (% move-dotted-rest-to-dmap (cgen V (cons t-dbound X) Y s-dty t-dty) t-dbound s-dbound))]

          ;; they're subtypes. easy.
          [(a b) 
           #:when (subtype a b)
           empty]

          ;; refinements are erased to their bound
          [((Refinement: S _) T)
           (cg S T)]

          ;; variables that are in X and should be constrained
          ;; all other variables are compatible only with themselves
          [((F: (? (λ (e) (memq e X)) v)) T)
           #:return-when
           (match T
             ;; fail when v* is an index variable
             [(F: v*) (and (bound-index? v*) (not (bound-tvar? v*)))]
             [_ #f])
           #f
           ;; constrain v to be below T (but don't mention V)
           (singleton (Un) v (var-demote T V))]

          [(S (F: (? (lambda (e) (memq e X)) v)))
           #:return-when
           (match S
             [(F: v*) (and (bound-index? v*) (not (bound-tvar? v*)))]
             [_ #f])
           #f
           ;; constrain v to be above S (but don't mention V)
           (singleton (var-promote S V) v Univ)]

          ;; recursive names should get resolved as they're seen
          [(s (? Name? t))
           (cg s (resolve-once t))]
          [((? Name? s) t)
           (cg (resolve-once s) t)]

          ;; constrain b1 to be below T, but don't mention the new vars
          [((Poly: v1 b1) T) (cgen (append v1 V) X Y b1 T)]

          ;; constrain *each* element of es to be below T, and then combine the constraints
          [((Union: es) T)
           (define cs (for/list/fail ([e (in-list es)]) (cg e T)))
           (and cs (cset-meet* (cons empty cs)))]

          ;; find *an* element of es which can be made to be a supertype of S
          ;; FIXME: we're using multiple csets here, but I don't think it makes a difference
          ;; not using multiple csets will break for: ???
          [(S (Union: es))
           (cset-join
            (for*/list ([e (in-list es)]
                        [v (in-value (cg S e))]
                        #:when v)
              v))]

          ;; two structs with the same name
          ;; just check pairwise on the fields
          [((Struct: nm _ flds proc _ _) (Struct: nm* _ flds* proc* _ _))
           #:when (free-identifier=? nm nm*)
           (let ([proc-c
                  (cond [(and proc proc*)
                         (cg proc proc*)]
                        [proc* #f]
                        [else empty])])
             (% cset-meet proc-c (cgen/flds V X Y flds flds*)))]

          ;; two struct names, need to resolve b/c one could be a parent
          [((Name: n _ _ #t) (Name: n* _ _ #t))
           (if (free-identifier=? n n*)
               empty ;; just succeed now
               (% cg (resolve-once S) (resolve-once T)))]
          ;; pairs are pointwise
          [((Pair: a b) (Pair: a* b*))
           (% cset-meet (cg a a*) (cg b b*))]
          ;; sequences are covariant
          [((Sequence: ts) (Sequence: ts*))
           (cgen/list V X Y ts ts*)]
          [((Listof: t) (Sequence: (list t*)))
           (cg t t*)]
          [((Pair: t1 t2) (Sequence: (list t*)))
           (% cset-meet (cg t1 t*) (cg t2 (-lst t*)))]
          [((MListof: t) (Sequence: (list t*)))
           (cg t t*)]
          ;; To check that mutable pair is a sequence we check that the cdr is
          ;; both an mutable list and a sequence
          [((MPair: t1 t2) (Sequence: (list t*)))
           (% cset-meet (cg t1 t*) (cg t2 T) (cg t2 (Un -Null (make-MPairTop))))]
          [((List: ts) (Sequence: (list t*)))
           (% cset-meet* (for/list/fail ([t (in-list ts)])
                           (cg t t*)))]
          [((HeterogeneousVector: ts) (HeterogeneousVector: ts*))
           (% cset-meet (cgen/list V X Y ts ts*) (cgen/list V X Y ts* ts))]
          [((HeterogeneousVector: ts) (Vector: s))
           (define ts* (map (λ _ s) ts)) ;; invariant, everything has to match
           (% cset-meet (cgen/list V X Y ts ts*) (cgen/list V X Y ts* ts))]
          [((HeterogeneousVector: ts) (Sequence: (list t*)))
           (% cset-meet* (for/list/fail ([t (in-list ts)])
                           (cg t t*)))]
          [((Vector: t) (Sequence: (list t*)))
           (cg t t*)]
          [((Base: 'String _ _ _) (Sequence: (list t*)))
           (cg -Char t*)]
          [((Base: 'Bytes _ _ _) (Sequence: (list t*)))
           (cg -Nat t*)]
          [((Base: 'Input-Port _ _ _) (Sequence: (list t*)))
           (cg -Nat t*)]
          [((Value: (? exact-nonnegative-integer? n)) (Sequence: (list t*)))
           (define possibilities
             (list
               (list byte? -Byte)
               (list portable-index? -Index)
               (list portable-fixnum? -NonNegFixnum)
               (list values -Nat)))
           (define type
             (for/or ([pred-type (in-list possibilities)])
               (match pred-type
                 ((list pred? type)
                  (and (pred? n) type)))))
           (cg type t*)]
          [((Base: _ _ _ #t) (Sequence: (list t*)))
           (define type
             (for/or ([t (in-list (list -Byte -Index -NonNegFixnum -Nat))])
               (and (subtype S t) t)))
           (% cg type t*)]
          [((Hashtable: k v) (Sequence: (list k* v*)))
           (cgen/list V X Y (list k v) (list k* v*))]
          [((Set: t) (Sequence: (list t*)))
           (cg t t*)]
          ;; ListDots can be below a Listof
          ;; must be above mu unfolding
          [((ListDots: s-dty dbound) (Listof: t-elem))
           #:return-when (memq dbound Y) #f
           (cgen V X Y (substitute Univ dbound s-dty) t-elem)]
          ;; two ListDots with the same bound, just check the element type
          ;; This is conservative because we don't try to infer a constraint on dbound.
          [((ListDots: s-dty dbound) (ListDots: t-dty dbound))
           (cgen V X Y s-dty t-dty)]
          [((ListDots: s-dty (? (λ (db) (memq db Y)) s-dbound)) (ListDots: t-dty t-dbound))
           ;; What should we do if both are in Y?
           #:return-when (memq t-dbound Y) #f
           (move-dotted-rest-to-dmap (cgen V (cons s-dbound X) Y s-dty t-dty) s-dbound t-dbound)]
          [((ListDots: s-dty s-dbound) (ListDots: t-dty (? (λ (db) (memq db Y)) t-dbound)))
           ;; s-dbound can't be in Y, due to previous rule
           (move-dotted-rest-to-dmap (cgen V (cons t-dbound X) Y s-dty t-dty) t-dbound s-dbound)]

          ;; this constrains `dbound' to be |ts| - |ss|
          [((ListDots: s-dty dbound) (List: ts))
           #:return-unless (memq dbound Y) #f
           (let* ([vars     (var-store-take dbound s-dty (length ts))]
                  ;; new-tys are dummy plain type variables, 
                  ;; standing in for the elements of dbound that need to be generated
                  [new-tys  (for/list ([var (in-list vars)])
                              (substitute (make-F var) dbound s-dty))]
                  ;; generate constraints on the prefixes, and on the dummy types
                  [new-cset (cgen/list V (append vars X) Y new-tys ts)])
             ;; now take all the dummy types, and use them to constrain dbound appropriately
             (% move-vars-to-dmap new-cset dbound vars))]

          ;; same as above, constrains `dbound' to be |ss| - |ts|
          [((List: ss) (ListDots: t-dty dbound))
           #:return-unless (memq dbound Y) #f

           ;; see comments for last case, we flip s and t though
           (let* ([vars     (var-store-take dbound t-dty (length ss))]
                  [new-tys  (for/list ([var (in-list vars)])
                              (substitute (make-F var) dbound t-dty))]
                  [new-cset (cgen/list V (append vars X) Y ss new-tys)])
             (move-vars-to-dmap new-cset dbound vars))]

          ;; if we have two mu's, we rename them to have the same variable
          ;; and then compare the bodies
          ;; This relies on (B 0) only unifying with itself, 
          ;; and thus only hitting the first case of this `match'
          [((Mu-unsafe: s) (Mu-unsafe: t))
           (cg s t)]

          ;; other mu's just get unfolded
          [(s (? Mu? t)) (cg s (unfold t))]
          [((? Mu? s) t) (cg (unfold s) t)]

          ;; resolve applications
          [((App: _ _ _) _)
           (% cg (resolve-once S) T)]
          [(_ (App: _ _ _))
           (% cg S (resolve-once T))]

          ;; If the struct names don't match, try the parent of S
          ;; Needs to be done after App and Mu in case T is actually the current struct
          ;; but not currently visible
          [((Struct: nm (? Type? parent) _ _ _ _) other)
           (cg parent other)]

          ;; Invariant here because struct types aren't subtypes just because the
          ;; structs are (since you can make a constructor from the type).
          [((StructType: s) (StructType: t))
           (cg/inv s t)]

          ;; vectors are invariant - generate constraints *both* ways
          [((Vector: e) (Vector: e*))
           (cg/inv e e*)]
          ;; boxes are invariant - generate constraints *both* ways
          [((Box: e) (Box: e*))
           (cg/inv e e*)]
          [((MPair: s t) (MPair: s* t*))
           (% cset-meet (cg/inv s s*) (cg/inv t t*))]
          [((Channel: e) (Channel: e*))
           (cg/inv e e*)]
          [((ThreadCell: e) (ThreadCell: e*))
           (cg/inv e e*)]
          [((Continuation-Mark-Keyof: e) (Continuation-Mark-Keyof: e*))
           (cg/inv e e*)]
          [((Prompt-Tagof: s t) (Prompt-Tagof: s* t*))
           (% cset-meet (cg/inv s s*) (cg/inv t t*))]
          [((Promise: e) (Promise: e*))
           (cg e e*)]
          [((Ephemeron: e) (Ephemeron: e*))
           (cg e e*)]
          [((CustodianBox: e) (CustodianBox: e*))
           (cg e e*)]
          [((Set: a) (Set: a*))
           (cg a a*)]
          [((Evt: a) (Evt: a*))
           (cg a a*)]
          [((Base: 'Semaphore _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'Output-Port _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'Input-Port _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'TCP-Listener _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'Thread _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'Subprocess _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'Will-Executor _ _ _) (Evt: t))
           (cg S t)]
          [((Base: 'LogReceiver _ _ _) (Evt: t ))
           (cg (make-HeterogeneousVector
                   (list -Symbol -String Univ
                         (Un (-val #f) -Symbol)))
               t)]
          [((CustodianBox: t) (Evt: t*)) (cg S t*)]
          [((Channel: t) (Evt: t*)) (cg t t*)]
          ;; we assume all HTs are mutable at the moment
          [((Hashtable: s1 s2) (Hashtable: t1 t2))
           ;; for mutable hash tables, both are invariant
           (% cset-meet (cg/inv s1 t1) (cg/inv s2 t2))]
          ;; syntax is covariant
          [((Syntax: s1) (Syntax: s2))
           (cg s1 s2)]
          ;; futures are covariant
          [((Future: s1) (Future: s2))
           (cg s1 s2)]
          ;; parameters are just like one-arg functions
          [((Param: in1 out1) (Param: in2 out2))
           (% cset-meet (cg in2 in1) (cg out1 out2))]
          ;; every function is trivially below top-arr
          [((Function: _)
            (Function: (list (top-arr:))))
           empty]
          [((Function: (list s-arr ...))
            (Function: (list t-arr ...)))
           (% cset-meet*
            (for/list/fail ([t-arr (in-list t-arr)])
              ;; for each element of t-arr, we need to get at least one element of s-arr that works
              (let ([results (for*/list ([s-arr (in-list s-arr)]
                                         [v (in-value (cgen/arr V X Y s-arr t-arr))]
                                         #:when v)
                               v)])
                ;; ensure that something produces a constraint set
                (and (not (null? results))
                     (cset-join results)))))]
          [(_ _)
           ;; nothing worked, and we fail
           #f]))))

;; C : cset? - set of constraints found by the inference engine
;; Y : (listof symbol?) - index variables that must have entries
;; R : Type/c - result type into which we will be substituting
(define/cond-contract (subst-gen C Y R)
  (cset? (listof symbol?) (or/c Values/c AnyValues? ValuesDots?) . -> . (or/c #f substitution/c))
  (define var-hash (free-vars-hash (free-vars* R)))
  (define idx-hash (free-vars-hash (free-idxs* R)))
  ;; v : Symbol - variable for which to check variance
  ;; h : (Hash Symbol Variance) - hash to check variance in (either var or idx hash)
  ;; variable: Symbol - variable to use instead, if v was a temp var for idx extension
  (define (constraint->type v h #:variable [variable #f])
    (match v
      [(c S X T)
       (let ([var (hash-ref h (or variable X) Constant)])
         ;(printf "variance was: ~a\nR was ~a\nX was ~a\nS T ~a ~a\n" var R (or variable X) S T)
         (evcase var
                 [Constant S]
                 [Covariant S]
                 [Contravariant T]
                 [Invariant
                  (let ([gS (generalize S)])
                    ;(printf "Inv var: ~a ~a ~a ~a\n" v S gS T)
                    (if (subtype gS T)
                        gS
                        S))]))]))
  ;; Since we don't add entries to the empty cset for index variables (since there is no
  ;; widest constraint, due to dcon-exacts), we must add substitutions here if no constraint
  ;; was found.  If we're at this point and had no other constraints, then adding the
  ;; equivalent of the constraint (dcon null (c Bot X Top)) is okay.
  (define (extend-idxs S)
    (define fi-R (fi R))
    ;; If the index variable v is not used in the type, then
    ;; we allow it to be replaced with the empty list of types;
    ;; otherwise we error, as we do not yet know what an appropriate
    ;; lower bound is.
    (define (demote/check-free v)
      (if (memq v fi-R)
          (int-err "attempted to demote dotted variable")
          (i-subst null)))
    ;; absent-entries is #f if there's an error in the substitution, otherwise
    ;; it's a list of variables that don't appear in the substitution
    (define absent-entries
      (for/fold ([no-entry null]) ([v (in-list Y)])
        (let ([entry (hash-ref S v #f)])
          ;; Make sure we got a subst entry for an index var
          ;; (i.e. a list of types for the fixed portion
          ;;  and a type for the starred portion)
          (cond
            [(not no-entry) no-entry]
            [(not entry) (cons v no-entry)]
            [(or (i-subst? entry) (i-subst/starred? entry) (i-subst/dotted? entry)) no-entry]
            [else #f]))))
    (and absent-entries
         (hash-union
          (for/hash ([missing (in-list absent-entries)])
            (let ([var (hash-ref idx-hash missing Constant)])
              (values missing
                      (evcase var
                              [Constant (demote/check-free missing)]
                              [Covariant (demote/check-free missing)]
                              [Contravariant (i-subst/starred null Univ)]
                              [Invariant (demote/check-free missing)]))))
          S)))
  (match (car (cset-maps C))
    [(cons cmap (dmap dm))
     (let ([subst (hash-union
                   (for/hash ([(k dc) (in-hash dm)])
                     (match dc
                       [(dcon fixed #f)
                        (values k
                                (i-subst
                                 (for/list ([f fixed])
                                   (constraint->type f idx-hash #:variable k))))]
                       [(dcon fixed rest)
                        (values k
                                (i-subst/starred (for/list ([f (in-list fixed)])
                                                   (constraint->type f idx-hash #:variable k))
                                                 (constraint->type rest idx-hash)))]
                       [(dcon-exact fixed rest)
                        (values k
                                (i-subst/starred
                                 (for/list ([f (in-list fixed)])
                                   (constraint->type f idx-hash #:variable k))
                                 (constraint->type rest idx-hash)))]
                       [(dcon-dotted fixed dc dbound)
                        (values k
                                (i-subst/dotted
                                 (for/list ([f (in-list fixed)])
                                   (constraint->type f idx-hash #:variable k))
                                 (constraint->type dc idx-hash #:variable k)
                                 dbound))]))
                   (for/hash ([(k v) (in-hash cmap)])
                     (values k (t-subst (constraint->type v var-hash)))))])
       ;; verify that we got all the important variables
       (and (for/and ([v (in-list (fv R))])
              (let ([entry (hash-ref subst v #f)])
                ;; Make sure we got a subst entry for a type var
                ;; (i.e. just a type to substitute)
                (and entry (t-subst? entry))))
            (extend-idxs subst)))]))

;; V : a set of variables not to mention in the constraints
;; X : the set of type variables to be constrained
;; Y : the set of index variables to be constrained
;; S : a list of types to be the subtypes of T
;; T : a list of types
;; expected-cset : a cset representing the expected type, to meet early and
;;  keep the number of constraints in check. (empty by default)
;; produces a cset which determines a substitution that makes the Ss subtypes of the Ts
(define/cond-contract (cgen/list V X Y S T
                                 #:expected-cset [expected-cset (empty-cset '() '())])
  (((listof symbol?) (listof symbol?) (listof symbol?) (listof Values/c) (listof Values/c))
   (#:expected-cset cset?) . ->* . (or/c cset? #f))
  (and (= (length S) (length T))
       (% cset-meet*
          (for/list/fail ([s (in-list S)] [t (in-list T)])
                         ;; We meet early to prune the csets to a reasonable size.
                         ;; This weakens the inference a bit, but sometimes avoids
                         ;; constraint explosion.
            (% cset-meet (cgen V X Y s t) expected-cset)))))



;; X : variables to infer
;; Y : indices to infer
;; S : actual argument types
;; T : formal argument types
;; R : result type
;; expected : #f or the expected type
;; returns a substitution
;; if R is #f, we don't care about the substituion
;; just return a boolean result
(define infer
 (let ()
  (define/cond-contract (infer X Y S T R [expected #f])
    (((listof symbol?) (listof symbol?) (listof Type/c) (listof Type/c)
      (or/c #f Values/c ValuesDots?))
     ((or/c #f Values/c AnyValues? ValuesDots?))
     . ->* . (or/c boolean? substitution/c))
    (let* ([expected-cset (if expected
                              (cgen null X Y R expected)
                              (empty-cset '() '()))]
           [cs  (and expected-cset
                     (cgen/list null X Y S T #:expected-cset expected-cset))]
           [cs* (% cset-meet cs expected-cset)])
      (and cs* (if R (subst-gen cs* Y R) #t))))
   infer)) ;to export a variable binding and not syntax

;; like infer, but T-var is the vararg type:
(define (infer/vararg X Y S T T-var R [expected #f])
  (define new-T (if T-var (extend S T T-var) T))
  (and ((length S) . >= . (length T))
       (infer X Y S new-T R expected)))

;; like infer, but dotted-var is the bound on the ...
;; and T-dotted is the repeated type
(define (infer/dots X dotted-var S T T-dotted R must-vars #:expected [expected #f])
  (early-return
   (define short-S (take S (length T)))
   (define rest-S (drop S (length T)))
   (define expected-cset (if expected
                             (cgen null X (list dotted-var) R expected)
                             (empty-cset '() '())))
   #:return-unless expected-cset #f
   (define cs-short (cgen/list null X (list dotted-var) short-S T
                               #:expected-cset expected-cset))
   #:return-unless cs-short #f
   (define new-vars (var-store-take dotted-var T-dotted (length rest-S)))
   (define new-Ts (for/list ([v (in-list new-vars)])
                            (substitute (make-F v) dotted-var
                                        (substitute-dots (map make-F new-vars)
                                                         #f dotted-var T-dotted))))
   (define cs-dotted (cgen/list null (append new-vars X) (list dotted-var) rest-S new-Ts
                                #:expected-cset expected-cset))
   #:return-unless cs-dotted #f
   (define cs-dotted* (move-vars-to-dmap cs-dotted dotted-var new-vars))
   #:return-unless cs-dotted* #f
   (define cs (cset-meet cs-short cs-dotted*))
   #:return-unless cs #f
   (define m (cset-meet cs expected-cset))
   #:return-unless m #f
   (subst-gen m (list dotted-var) R)))


