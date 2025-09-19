;; title: energy-token
;; Tokenized representation of renewable energy units for peer-to-peer trading

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u300))
(define-constant ERR-INSUFFICIENT-BALANCE (err u301))
(define-constant ERR-INVALID-AMOUNT (err u302))
(define-constant ERR-TOKEN-NOT-FOUND (err u303))
(define-constant ERR-PRODUCER-NOT-VERIFIED (err u304))
(define-constant ERR-INVALID-SOURCE-TYPE (err u305))

;; Source type constants
(define-constant SOURCE-SOLAR u1)
(define-constant SOURCE-WIND u2)
(define-constant SOURCE-HYDRO u3)
(define-constant SOURCE-GEOTHERMAL u4)
(define-constant SOURCE-BIOMASS u5)
(define-constant SOURCE-BATTERY u6)

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; Total supply tracking
(define-data-var total-supply uint u0)
(define-data-var next-token-id uint u1)

;; Energy producer registry
(define-map energy-producers
  { producer: principal }
  {
    verified: bool,
    total-produced: uint,
    reputation-score: uint,
    registered-at: uint,
    license-id: (string-ascii 50)
  }
)

;; Energy token balances
(define-map token-balances
  { owner: principal }
  { balance: uint }
)

;; Energy tokens metadata
(define-map energy-tokens
  { token-id: uint }
  {
    producer: principal,
    amount: uint,
    source-type: uint,
    production-date: uint,
    expiry-date: uint,
    price-per-unit: uint,
    carbon-offset: uint
  }
)

;; Energy transactions log
(define-map energy-transactions
  { tx-id: uint }
  {
    from: principal,
    to: principal,
    token-id: uint,
    amount: uint,
    price: uint,
    timestamp: uint
  }
)

;; Price history for market analysis
(define-map price-history
  { source-type: uint, timestamp: uint }
  {
    average-price: uint,
    volume: uint,
    transactions: uint
  }
)

;; Transaction counter
(define-data-var next-tx-id uint u0)

;; Helper functions
(define-private (is-valid-source-type (source-type uint))
  (and (>= source-type SOURCE-SOLAR) (<= source-type SOURCE-BATTERY))
)

(define-private (is-verified-producer (producer principal))
  (match (map-get? energy-producers { producer: producer })
    producer-data (get verified producer-data)
    false
  )
)

(define-private (get-balance (owner principal))
  (default-to u0 (get balance (map-get? token-balances { owner: owner })))
)

(define-private (set-balance (owner principal) (new-balance uint))
  (map-set token-balances { owner: owner } { balance: new-balance })
)

;; Public functions

;; Register energy producer
(define-public (register-producer (producer principal) (license-id (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-UNAUTHORIZED)
    (map-set energy-producers
      { producer: producer }
      {
        verified: false,
        total-produced: u0,
        reputation-score: u100,
        registered-at: block-height,
        license-id: license-id
      }
    )
    (ok true)
  )
)

;; Verify energy producer
(define-public (verify-producer (producer principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-UNAUTHORIZED)
    (match (map-get? energy-producers { producer: producer })
      producer-data
      (begin
        (map-set energy-producers
          { producer: producer }
          (merge producer-data { verified: true })
        )
        (ok true)
      )
      ERR-PRODUCER-NOT-VERIFIED
    )
  )
)

;; Mint energy tokens for verified producers
(define-public (mint-energy-token (amount uint) (source-type uint) (price-per-unit uint) (production-date uint))
  (let (
    (token-id (var-get next-token-id))
    (expiry-date (+ production-date u8760)) ;; 1 year expiry
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-valid-source-type source-type) ERR-INVALID-SOURCE-TYPE)
    (asserts! (is-verified-producer tx-sender) ERR-PRODUCER-NOT-VERIFIED)
    
    ;; Create energy token
    (map-set energy-tokens
      { token-id: token-id }
      {
        producer: tx-sender,
        amount: amount,
        source-type: source-type,
        production-date: production-date,
        expiry-date: expiry-date,
        price-per-unit: price-per-unit,
        carbon-offset: (* amount u10) ;; 10 kg CO2 offset per unit
      }
    )
    
    ;; Update producer stats
    (match (map-get? energy-producers { producer: tx-sender })
      producer-data
      (map-set energy-producers
        { producer: tx-sender }
        (merge producer-data { total-produced: (+ (get total-produced producer-data) amount) })
      )
      false
    )
    
    ;; Update total supply and next token ID
    (var-set total-supply (+ (var-get total-supply) amount))
    (var-set next-token-id (+ token-id u1))
    
    ;; Add to producer's balance
    (set-balance tx-sender (+ (get-balance tx-sender) amount))
    
    (ok token-id)
  )
)

;; Transfer energy tokens
(define-public (transfer-energy (recipient principal) (token-id uint) (amount uint))
  (let (
    (sender-balance (get-balance tx-sender))
    (recipient-balance (get-balance recipient))
    (tx-id (var-get next-tx-id))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= sender-balance amount) ERR-INSUFFICIENT-BALANCE)
    
    (match (map-get? energy-tokens { token-id: token-id })
      token-data
      (begin
        (asserts! (>= (get amount token-data) amount) ERR-INSUFFICIENT-BALANCE)
        
        ;; Update balances
        (set-balance tx-sender (- sender-balance amount))
        (set-balance recipient (+ recipient-balance amount))
        
        ;; Log transaction
        (map-set energy-transactions
          { tx-id: tx-id }
          {
            from: tx-sender,
            to: recipient,
            token-id: token-id,
            amount: amount,
            price: (get price-per-unit token-data),
            timestamp: block-height
          }
        )
        
        (var-set next-tx-id (+ tx-id u1))
        (ok true)
      )
      ERR-TOKEN-NOT-FOUND
    )
  )
)

;; Burn energy tokens when consumed
(define-public (burn-energy-token (token-id uint) (amount uint))
  (let (
    (owner-balance (get-balance tx-sender))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= owner-balance amount) ERR-INSUFFICIENT-BALANCE)
    
    (match (map-get? energy-tokens { token-id: token-id })
      token-data
      (begin
        (asserts! (>= (get amount token-data) amount) ERR-INSUFFICIENT-BALANCE)
        
        ;; Update token amount
        (map-set energy-tokens
          { token-id: token-id }
          (merge token-data { amount: (- (get amount token-data) amount) })
        )
        
        ;; Update owner balance
        (set-balance tx-sender (- owner-balance amount))
        
        ;; Update total supply
        (var-set total-supply (- (var-get total-supply) amount))
        
        (ok true)
      )
      ERR-TOKEN-NOT-FOUND
    )
  )
)

;; Set energy token price
(define-public (set-token-price (token-id uint) (new-price uint))
  (match (map-get? energy-tokens { token-id: token-id })
    token-data
    (begin
      (asserts! (is-eq tx-sender (get producer token-data)) ERR-UNAUTHORIZED)
      (map-set energy-tokens
        { token-id: token-id }
        (merge token-data { price-per-unit: new-price })
      )
      (ok true)
    )
    ERR-TOKEN-NOT-FOUND
  )
)

;; Read-only functions

;; Get energy token details
(define-read-only (get-energy-token (token-id uint))
  (map-get? energy-tokens { token-id: token-id })
)

;; Get energy producer info
(define-read-only (get-producer-info (producer principal))
  (map-get? energy-producers { producer: producer })
)

;; Get balance
(define-read-only (get-energy-balance (owner principal))
  (get-balance owner)
)

;; Get transaction details
(define-read-only (get-transaction (tx-id uint))
  (map-get? energy-transactions { tx-id: tx-id })
)

;; Get total supply
(define-read-only (get-total-supply)
  (var-get total-supply)
)

;; Get current token price by source type
(define-read-only (get-source-type-name (source-type uint))
  (if (is-eq source-type SOURCE-SOLAR) "solar"
    (if (is-eq source-type SOURCE-WIND) "wind"
      (if (is-eq source-type SOURCE-HYDRO) "hydro"
        (if (is-eq source-type SOURCE-GEOTHERMAL) "geothermal"
          (if (is-eq source-type SOURCE-BIOMASS) "biomass"
            (if (is-eq source-type SOURCE-BATTERY) "battery"
              "unknown"
            )
          )
        )
      )
    )
  )
)

;; Check if token is expired
(define-read-only (is-token-expired (token-id uint))
  (match (map-get? energy-tokens { token-id: token-id })
    token-data
    (> block-height (get expiry-date token-data))
    false
  )
)
