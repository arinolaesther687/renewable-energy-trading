;; title: grid-settlement
;; Automated settlement system for renewable energy transactions and grid balancing

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u400))
(define-constant ERR-LISTING-NOT-FOUND (err u401))
(define-constant ERR-INSUFFICIENT-FUNDS (err u402))
(define-constant ERR-INVALID-AMOUNT (err u403))
(define-constant ERR-LISTING-EXPIRED (err u404))
(define-constant ERR-TRANSACTION-NOT-FOUND (err u405))
(define-constant ERR-ALREADY-SETTLED (err u406))

;; Settlement status constants
(define-constant STATUS-PENDING u1)
(define-constant STATUS-COMPLETED u2)
(define-constant STATUS-CANCELLED u3)
(define-constant STATUS-DISPUTED u4)

;; Contract owner for system operations
(define-data-var contract-owner principal tx-sender)

;; Listing and transaction counters
(define-data-var next-listing-id uint u1)
(define-data-var next-transaction-id uint u1)

;; Energy listings marketplace
(define-map energy-listings
  { listing-id: uint }
  {
    seller: principal,
    amount-available: uint,
    price-per-unit: uint,
    source-type: uint,
    location: (string-ascii 50),
    created-at: uint,
    expires-at: uint,
    active: bool,
    total-sold: uint
  }
)

;; Energy purchase transactions
(define-map energy-purchases
  { transaction-id: uint }
  {
    listing-id: uint,
    buyer: principal,
    seller: principal,
    amount: uint,
    total-price: uint,
    created-at: uint,
    status: uint,
    delivery-confirmed: bool,
    payment-released: bool
  }
)

;; Grid balancing data
(define-map grid-zones
  { zone-id: (string-ascii 50) }
  {
    current-demand: uint,
    current-supply: uint,
    price-multiplier: uint,
    last-updated: uint
  }
)

;; User balances in the settlement system
(define-map user-balances
  { user: principal }
  { balance: uint }
)

;; Escrow for pending transactions
(define-map transaction-escrow
  { transaction-id: uint }
  {
    amount: uint,
    locked-at: uint,
    release-at: uint
  }
)

;; Dispute resolution
(define-map transaction-disputes
  { transaction-id: uint }
  {
    reporter: principal,
    reason: (string-ascii 200),
    reported-at: uint,
    resolved: bool,
    resolution: (string-ascii 200)
  }
)

;; Helper functions
(define-private (get-user-balance (user principal))
  (default-to u0 (get balance (map-get? user-balances { user: user })))
)

(define-private (set-user-balance (user principal) (new-balance uint))
  (map-set user-balances { user: user } { balance: new-balance })
)

(define-private (is-listing-expired (expires-at uint))
  (> block-height expires-at)
)

(define-private (calculate-grid-price (base-price uint) (zone-id (string-ascii 50)))
  (match (map-get? grid-zones { zone-id: zone-id })
    zone-data
    (* base-price (get price-multiplier zone-data))
    base-price
  )
)

;; Public functions

;; Deposit funds to user balance
(define-public (deposit-funds (amount uint))
  (let ((current-balance (get-user-balance tx-sender)))
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (set-user-balance tx-sender (+ current-balance amount))
    (ok true)
  )
)

;; Withdraw funds from user balance
(define-public (withdraw-funds (amount uint))
  (let ((current-balance (get-user-balance tx-sender)))
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= current-balance amount) ERR-INSUFFICIENT-FUNDS)
    (set-user-balance tx-sender (- current-balance amount))
    (ok true)
  )
)

;; Create energy listing
(define-public (create-energy-listing (amount uint) (price-per-unit uint) (source-type uint) (location (string-ascii 50)) (duration uint))
  (let (
    (listing-id (var-get next-listing-id))
    (expires-at (+ block-height duration))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> price-per-unit u0) ERR-INVALID-AMOUNT)
    
    (map-set energy-listings
      { listing-id: listing-id }
      {
        seller: tx-sender,
        amount-available: amount,
        price-per-unit: price-per-unit,
        source-type: source-type,
        location: location,
        created-at: block-height,
        expires-at: expires-at,
        active: true,
        total-sold: u0
      }
    )
    
    (var-set next-listing-id (+ listing-id u1))
    (ok listing-id)
  )
)

;; Purchase energy from listing
(define-public (purchase-energy (listing-id uint) (amount uint))
  (let (
    (transaction-id (var-get next-transaction-id))
    (buyer-balance (get-user-balance tx-sender))
  )
    (match (map-get? energy-listings { listing-id: listing-id })
      listing-data
      (let (
        (total-price (* amount (get price-per-unit listing-data)))
        (adjusted-price (calculate-grid-price total-price (get location listing-data)))
      )
        (asserts! (get active listing-data) ERR-LISTING-NOT-FOUND)
        (asserts! (not (is-listing-expired (get expires-at listing-data))) ERR-LISTING-EXPIRED)
        (asserts! (<= amount (get amount-available listing-data)) ERR-INVALID-AMOUNT)
        (asserts! (>= buyer-balance adjusted-price) ERR-INSUFFICIENT-FUNDS)
        
        ;; Lock funds in escrow
        (set-user-balance tx-sender (- buyer-balance adjusted-price))
        (map-set transaction-escrow
          { transaction-id: transaction-id }
          {
            amount: adjusted-price,
            locked-at: block-height,
            release-at: (+ block-height u144) ;; 24 hours for delivery confirmation
          }
        )
        
        ;; Create purchase transaction
        (map-set energy-purchases
          { transaction-id: transaction-id }
          {
            listing-id: listing-id,
            buyer: tx-sender,
            seller: (get seller listing-data),
            amount: amount,
            total-price: adjusted-price,
            created-at: block-height,
            status: STATUS-PENDING,
            delivery-confirmed: false,
            payment-released: false
          }
        )
        
        ;; Update listing availability
        (map-set energy-listings
          { listing-id: listing-id }
          (merge listing-data {
            amount-available: (- (get amount-available listing-data) amount),
            total-sold: (+ (get total-sold listing-data) amount)
          })
        )
        
        (var-set next-transaction-id (+ transaction-id u1))
        (ok transaction-id)
      )
      ERR-LISTING-NOT-FOUND
    )
  )
)

;; Confirm energy delivery
(define-public (confirm-delivery (transaction-id uint))
  (match (map-get? energy-purchases { transaction-id: transaction-id })
    transaction-data
    (begin
      (asserts! (is-eq tx-sender (get buyer transaction-data)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status transaction-data) STATUS-PENDING) ERR-ALREADY-SETTLED)
      
      ;; Update transaction status
      (map-set energy-purchases
        { transaction-id: transaction-id }
        (merge transaction-data { delivery-confirmed: true })
      )
      
      (ok true)
    )
    ERR-TRANSACTION-NOT-FOUND
  )
)

;; Settle transaction (release payment to seller)
(define-public (settle-transaction (transaction-id uint))
  (match (map-get? energy-purchases { transaction-id: transaction-id })
    transaction-data
    (begin
      (asserts! (or 
        (is-eq tx-sender (get seller transaction-data))
        (is-eq tx-sender (var-get contract-owner))
      ) ERR-UNAUTHORIZED)
      (asserts! (get delivery-confirmed transaction-data) ERR-UNAUTHORIZED)
      (asserts! (not (get payment-released transaction-data)) ERR-ALREADY-SETTLED)
      
      (match (map-get? transaction-escrow { transaction-id: transaction-id })
        escrow-data
        (let (
          (seller (get seller transaction-data))
          (seller-balance (get-user-balance seller))
          (escrow-amount (get amount escrow-data))
        )
          ;; Release payment to seller
          (set-user-balance seller (+ seller-balance escrow-amount))
          
          ;; Update transaction status
          (map-set energy-purchases
            { transaction-id: transaction-id }
            (merge transaction-data { 
              status: STATUS-COMPLETED,
              payment-released: true
            })
          )
          
          ;; Remove from escrow
          (map-delete transaction-escrow { transaction-id: transaction-id })
          
          (ok true)
        )
        ERR-TRANSACTION-NOT-FOUND
      )
    )
    ERR-TRANSACTION-NOT-FOUND
  )
)

;; Cancel listing
(define-public (cancel-listing (listing-id uint))
  (match (map-get? energy-listings { listing-id: listing-id })
    listing-data
    (begin
      (asserts! (is-eq tx-sender (get seller listing-data)) ERR-UNAUTHORIZED)
      (map-set energy-listings
        { listing-id: listing-id }
        (merge listing-data { active: false })
      )
      (ok true)
    )
    ERR-LISTING-NOT-FOUND
  )
)

;; Report transaction dispute
(define-public (report-dispute (transaction-id uint) (reason (string-ascii 200)))
  (match (map-get? energy-purchases { transaction-id: transaction-id })
    transaction-data
    (begin
      (asserts! (or 
        (is-eq tx-sender (get buyer transaction-data))
        (is-eq tx-sender (get seller transaction-data))
      ) ERR-UNAUTHORIZED)
      
      (map-set transaction-disputes
        { transaction-id: transaction-id }
        {
          reporter: tx-sender,
          reason: reason,
          reported-at: block-height,
          resolved: false,
          resolution: ""
        }
      )
      
      ;; Update transaction status
      (map-set energy-purchases
        { transaction-id: transaction-id }
        (merge transaction-data { status: STATUS-DISPUTED })
      )
      
      (ok true)
    )
    ERR-TRANSACTION-NOT-FOUND
  )
)

;; Update grid zone data (admin only)
(define-public (update-grid-zone (zone-id (string-ascii 50)) (demand uint) (supply uint) (multiplier uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-UNAUTHORIZED)
    (map-set grid-zones
      { zone-id: zone-id }
      {
        current-demand: demand,
        current-supply: supply,
        price-multiplier: multiplier,
        last-updated: block-height
      }
    )
    (ok true)
  )
)

;; Read-only functions

;; Get energy listing details
(define-read-only (get-energy-listing (listing-id uint))
  (map-get? energy-listings { listing-id: listing-id })
)

;; Get transaction details
(define-read-only (get-energy-purchase (transaction-id uint))
  (map-get? energy-purchases { transaction-id: transaction-id })
)

;; Get user balance
(define-read-only (get-balance (user principal))
  (get-user-balance user)
)

;; Get grid zone information
(define-read-only (get-grid-zone (zone-id (string-ascii 50)))
  (map-get? grid-zones { zone-id: zone-id })
)

;; Get escrow details
(define-read-only (get-escrow-details (transaction-id uint))
  (map-get? transaction-escrow { transaction-id: transaction-id })
)

;; Get dispute details
(define-read-only (get-dispute-details (transaction-id uint))
  (map-get? transaction-disputes { transaction-id: transaction-id })
)

;; Check if listing is active and not expired
(define-read-only (is-listing-active (listing-id uint))
  (match (map-get? energy-listings { listing-id: listing-id })
    listing-data
    (and 
      (get active listing-data)
      (not (is-listing-expired (get expires-at listing-data)))
      (> (get amount-available listing-data) u0)
    )
    false
  )
)
