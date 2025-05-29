;; flexhive-marketplace
;; 
;; A decentralized marketplace contract for connecting freelancers with clients
;; This contract manages the full lifecycle of gigs including posting, proposals,
;; assignment, milestone payments, work submission, and dispute resolution.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-JOB-NOT-FOUND (err u101))
(define-constant ERR-INVALID-STATUS (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u104))
(define-constant ERR-USER-NOT-FOUND (err u105))
(define-constant ERR-ALREADY-EXISTS (err u106))
(define-constant ERR-PROPOSAL-ALREADY-SUBMITTED (err u107))
(define-constant ERR-JOB-CLOSED (err u108))
(define-constant ERR-NOT-ASSIGNEE (err u109))
(define-constant ERR-NOT-CLIENT (err u110))
(define-constant ERR-NO-ACTIVE-DISPUTE (err u111))
(define-constant ERR-NOT-ARBITER (err u112))
(define-constant ERR-MILESTONE-NOT-FOUND (err u113))
(define-constant ERR-MILESTONE-ALREADY-PAID (err u114))
(define-constant ERR-DEADLINE-PASSED (err u115))

;; Job status constants
(define-constant STATUS-OPEN u1)
(define-constant STATUS-ASSIGNED u2)
(define-constant STATUS-COMPLETED u3)
(define-constant STATUS-CANCELLED u4)
(define-constant STATUS-DISPUTED u5)

;; Platform fee percentage (1% = 10, 5% = 50, etc., out of 1000)
(define-constant PLATFORM-FEE-BPS u25) ;; 2.5%

;; Admin principal (for managing arbiters and collecting fees)
(define-data-var contract-owner principal tx-sender)

;; Data Maps

;; Job listings
(define-map jobs
  { job-id: uint }
  {
    client: principal,
    title: (string-ascii 100),
    description: (string-utf8 1000),
    total-amount: uint,
    remaining-amount: uint,
    deadline: uint,
    status: uint,
    assignee: (optional principal),
    created-at: uint
  }
)

;; Job proposals
(define-map proposals
  { job-id: uint, freelancer: principal }
  {
    proposal-text: (string-utf8 500),
    proposed-amount: uint,
    proposed-deadline: uint,
    submitted-at: uint
  }
)

;; Job milestones
(define-map milestones
  { job-id: uint, milestone-id: uint }
  {
    description: (string-utf8 200),
    amount: uint,
    is-paid: bool,
    completed-at: (optional uint)
  }
)

;; Disputes
(define-map disputes
  { job-id: uint }
  {
    initiated-by: principal,
    reason: (string-utf8 500),
    client-evidence: (optional (string-utf8 1000)),
    freelancer-evidence: (optional (string-utf8 1000)),
    arbiter: (optional principal),
    resolved: bool,
    resolution-details: (optional (string-utf8 500)),
    created-at: uint
  }
)

;; User reputation and stats
(define-map user-profiles
  { user: principal }
  {
    jobs-completed: uint,
    jobs-posted: uint,
    total-earned: uint,
    total-paid: uint,
    disputes-won: uint,
    disputes-lost: uint,
    reputation-score: uint,
    created-at: uint
  }
)

;; Approved arbiters
(define-map approved-arbiters 
  { arbiter: principal } 
  { approved: bool }
)

;; Counter for job IDs
(define-data-var job-id-counter uint u0)

;; Platform fee wallet
(define-data-var fee-address principal tx-sender)

;; Private Functions

;; Increment and return the next job ID
(define-private (get-next-job-id)
  (let ((next-id (+ (var-get job-id-counter) u1)))
    (var-set job-id-counter next-id)
    next-id
  )
)

;; Check if principal is an approved arbiter
(define-private (is-arbiter (user principal))
  (default-to false (get approved (map-get? approved-arbiters { arbiter: user })))
)

;; Calculate platform fee
(define-private (calculate-fee (amount uint))
  (/ (* amount PLATFORM-FEE-BPS) u1000)
)

;; Initialize user profile if not exists
(define-private (init-user-if-needed (user principal))
  (match (map-get? user-profiles { user: user })
    profile true
    (map-set user-profiles
      { user: user }
      {
        jobs-completed: u0,
        jobs-posted: u0,
        total-earned: u0,
        total-paid: u0,
        disputes-won: u0,
        disputes-lost: u0,
        reputation-score: u100, ;; Start with neutral reputation (scale 0-200)
        created-at: block-height
      }
    )
  )
)

;; Update user reputation after job completion
(define-private (update-reputation-after-completion (job-data (tuple (client principal) (assignee principal) (total-amount uint))))
  (let (
    (client (get client job-data))
    (assignee (get assignee job-data))
    (amount (get total-amount job-data))
    (client-profile (default-to 
      {
        jobs-completed: u0,
        jobs-posted: u0,
        total-earned: u0,
        total-paid: u0,
        disputes-won: u0,
        disputes-lost: u0,
        reputation-score: u100,
        created-at: block-height
      } 
      (map-get? user-profiles { user: client })))
    (freelancer-profile (default-to 
      {
        jobs-completed: u0,
        jobs-posted: u0,
        total-earned: u0,
        total-paid: u0,
        disputes-won: u0,
        disputes-lost: u0,
        reputation-score: u100,
        created-at: block-height
      } 
      (map-get? user-profiles { user: assignee })))
  )
    ;; Update client profile
    (map-set user-profiles
      { user: client }
      (merge client-profile {
        jobs-posted: (+ (get jobs-posted client-profile) u1),
        total-paid: (+ (get total-paid client-profile) amount),
        reputation-score: (+ (get reputation-score client-profile) u1) ;; Slight reputation boost
      })
    )
    
    ;; Update freelancer profile
    (map-set user-profiles
      { user: assignee }
      (merge freelancer-profile {
        jobs-completed: (+ (get jobs-completed freelancer-profile) u1),
        total-earned: (+ (get total-earned freelancer-profile) amount),
        reputation-score: (+ (get reputation-score freelancer-profile) u2) ;; Bigger reputation boost for completing work
      })
    )
  )
)

;; Public Functions

;; Post a new job
(define-public (post-job 
  (title (string-ascii 100)) 
  (description (string-utf8 1000)) 
  (total-amount uint) 
  (deadline uint))
  (let (
    (job-id (get-next-job-id))
    (client tx-sender)
  )
    ;; Validate inputs
    (asserts! (> total-amount u0) ERR-INSUFFICIENT-FUNDS)
    (asserts! (> deadline block-height) ERR-DEADLINE-PASSED)
    
    ;; Transfer funds to contract escrow
    (try! (stx-transfer? total-amount client (as-contract tx-sender)))
    
    ;; Initialize client if needed
    (init-user-if-needed client)
    
    ;; Create job listing
    (map-set jobs
      { job-id: job-id }
      {
        client: client,
        title: title,
        description: description,
        total-amount: total-amount,
        remaining-amount: total-amount,
        deadline: deadline,
        status: STATUS-OPEN,
        assignee: none,
        created-at: block-height
      }
    )
    
    (ok job-id)
  )
)

;; Submit a proposal for a job
(define-public (submit-proposal 
  (job-id uint) 
  (proposal-text (string-utf8 500))
  (proposed-amount uint)
  (proposed-deadline uint))
  (let (
    (freelancer tx-sender)
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate job exists and is open
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-OPEN) ERR-JOB-CLOSED)
    (asserts! (<= proposed-amount (get total-amount (unwrap-panic job))) ERR-INVALID-STATUS)
    (asserts! (> proposed-deadline block-height) ERR-DEADLINE-PASSED)
    
    ;; Check if freelancer already submitted a proposal
    (asserts! (is-none (map-get? proposals { job-id: job-id, freelancer: freelancer })) ERR-PROPOSAL-ALREADY-SUBMITTED)
    
    ;; Initialize freelancer if needed
    (init-user-if-needed freelancer)
    
    ;; Create proposal
    (map-set proposals
      { job-id: job-id, freelancer: freelancer }
      {
        proposal-text: proposal-text,
        proposed-amount: proposed-amount,
        proposed-deadline: proposed-deadline,
        submitted-at: block-height
      }
    )
    
    (ok true)
  )
)

;; Accept a proposal and assign job to freelancer
(define-public (accept-proposal (job-id uint) (freelancer principal))
  (let (
    (client tx-sender)
    (job (map-get? jobs { job-id: job-id }))
    (proposal (map-get? proposals { job-id: job-id, freelancer: freelancer }))
  )
    ;; Validate job exists and is open
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-OPEN) ERR-INVALID-STATUS)
    
    ;; Validate client is the job owner
    (asserts! (is-eq client (get client (unwrap-panic job))) ERR-NOT-CLIENT)
    
    ;; Validate proposal exists
    (asserts! (is-some proposal) ERR-PROPOSAL-NOT-FOUND)
    
    ;; Update job status
    (map-set jobs
      { job-id: job-id }
      (merge (unwrap-panic job) 
        { 
          status: STATUS-ASSIGNED,
          assignee: (some freelancer),
          deadline: (get proposed-deadline (unwrap-panic proposal))
        }
      )
    )
    
    (ok true)
  )
)

;; Add a milestone to a job
(define-public (add-milestone (job-id uint) (description (string-utf8 200)) (amount uint))
  (let (
    (client tx-sender)
    (job (map-get? jobs { job-id: job-id }))
    (milestone-id u0) ;; NOTE: This makes next-milestone-id always u1. The milestone ID generation logic likely needs further review.
    (next-milestone-id (+ milestone-id u1))
  )
    ;; Validate job exists
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    
    ;; Validate client is the job owner
    (asserts! (is-eq client (get client (unwrap-panic job))) ERR-NOT-CLIENT)
    
    ;; Validate amount is available in remaining funds
    (asserts! (<= amount (get remaining-amount (unwrap-panic job))) ERR-INSUFFICIENT-FUNDS)
    
    ;; Create milestone
    (map-set milestones
      { job-id: job-id, milestone-id: next-milestone-id }
      {
        description: description,
        amount: amount,
        is-paid: false,
        completed-at: none
      }
    )
    
    (ok next-milestone-id)
  )
)

;; Release payment for a specific milestone
(define-public (release-milestone-payment (job-id uint) (milestone-id uint))
  (let (
    (client tx-sender)
    (job (map-get? jobs { job-id: job-id }))
    (milestone (map-get? milestones { job-id: job-id, milestone-id: milestone-id }))
  )
    ;; Validate job exists and is assigned
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-ASSIGNED) ERR-INVALID-STATUS)
    
    ;; Validate client is the job owner
    (asserts! (is-eq client (get client (unwrap-panic job))) ERR-NOT-CLIENT)
    
    ;; Validate milestone exists and is not paid
    (asserts! (is-some milestone) ERR-MILESTONE-NOT-FOUND)
    (asserts! (not (get is-paid (unwrap-panic milestone))) ERR-MILESTONE-ALREADY-PAID)
    
    ;; Get assignee
    (let (
      (assignee (unwrap! (get assignee (unwrap-panic job)) ERR-NOT-ASSIGNEE))
      (amount (get amount (unwrap-panic milestone)))
      (fee (calculate-fee amount))
      (payment-amount (- amount fee))
      (remaining-amount (- (get remaining-amount (unwrap-panic job)) amount))
    )
      ;; Update milestone
      (map-set milestones
        { job-id: job-id, milestone-id: milestone-id }
        (merge (unwrap-panic milestone)
          {
            is-paid: true,
            completed-at: (some block-height)
          }
        )
      )
      
      ;; Update job remaining amount
      (map-set jobs
        { job-id: job-id }
        (merge (unwrap-panic job)
          { remaining-amount: remaining-amount }
        )
      )
      
      ;; Transfer payment to freelancer
      (try! (as-contract (stx-transfer? payment-amount tx-sender assignee)))
      
      ;; Transfer fee to platform
      (try! (as-contract (stx-transfer? fee tx-sender (var-get fee-address))))
      
      (ok true)
    )
  )
)

;; Submit work as completed
(define-public (submit-job-completion (job-id uint))
  (let (
    (freelancer tx-sender)
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate job exists and is assigned
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-ASSIGNED) ERR-INVALID-STATUS)
    
    ;; Validate freelancer is the assignee
    (asserts! (is-eq (some freelancer) (get assignee (unwrap-panic job))) ERR-NOT-ASSIGNEE)
    
    ;; Update job status to completed
    (map-set jobs
      { job-id: job-id }
      (merge (unwrap-panic job)
        { status: STATUS-COMPLETED }
      )
    )
    
    (ok true)
  )
)

;; Approve completed work and release remaining payment
(define-public (approve-job-completion (job-id uint))
  (let (
    (client tx-sender)
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate job exists and is marked as completed
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-COMPLETED) ERR-INVALID-STATUS)
    
    ;; Validate client is the job owner
    (asserts! (is-eq client (get client (unwrap-panic job))) ERR-NOT-CLIENT)
    
    ;; Process final payment if any remaining amount
    (let (
      (assignee (unwrap! (get assignee (unwrap-panic job)) ERR-NOT-ASSIGNEE))
      (remaining (get remaining-amount (unwrap-panic job)))
    )
      ;; If there are remaining funds, transfer them
      (if (> remaining u0)
        (let (
          (fee (calculate-fee remaining))
          (payment-amount (- remaining fee))
        )
          ;; Transfer payment to freelancer
          (try! (as-contract (stx-transfer? payment-amount tx-sender assignee)))
          
          ;; Transfer fee to platform
          (try! (as-contract (stx-transfer? fee tx-sender (var-get fee-address))))
          
          ;; Update job remaining amount to zero
          (map-set jobs
            { job-id: job-id }
            (merge (unwrap-panic job)
              { remaining-amount: u0 }
            )
          )
        )
        true
      )
      
      ;; Update user reputations
      (update-reputation-after-completion (tuple 
        (client (get client (unwrap-panic job)))
        (assignee assignee)
        (total-amount (get total-amount (unwrap-panic job)))
      ))
      
      (ok true)
    )
  )
)

;; Initiate a dispute
(define-public (initiate-dispute (job-id uint) (reason (string-utf8 500)))
  (let (
    (initiator tx-sender)
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate job exists and is assigned or completed
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (or 
      (is-eq (get status (unwrap-panic job)) STATUS-ASSIGNED)
      (is-eq (get status (unwrap-panic job)) STATUS-COMPLETED)
    ) ERR-INVALID-STATUS)
    
    ;; Validate initiator is either client or assignee
    (asserts! (or
      (is-eq initiator (get client (unwrap-panic job)))
      (is-eq (some initiator) (get assignee (unwrap-panic job)))
    ) ERR-NOT-AUTHORIZED)
    
    ;; Create dispute
    (map-set disputes
      { job-id: job-id }
      {
        initiated-by: initiator,
        reason: reason,
        client-evidence: none,
        freelancer-evidence: none,
        arbiter: none,
        resolved: false,
        resolution-details: none,
        created-at: block-height
      }
    )
    
    ;; Update job status
    (map-set jobs
      { job-id: job-id }
      (merge (unwrap-panic job)
        { status: STATUS-DISPUTED }
      )
    )
    
    (ok true)
  )
)

;; Submit evidence for a dispute
(define-public (submit-dispute-evidence (job-id uint) (evidence (string-utf8 1000)))
  (let (
    (user tx-sender)
    (job (map-get? jobs { job-id: job-id }))
    (dispute (map-get? disputes { job-id: job-id }))
  )
    ;; Validate job exists and is disputed
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-DISPUTED) ERR-INVALID-STATUS)
    
    ;; Validate dispute exists
    (asserts! (is-some dispute) ERR-NO-ACTIVE-DISPUTE)
    
    ;; Check if user is client or freelancer and update appropriate evidence
    (if (is-eq user (get client (unwrap-panic job)))
      (map-set disputes
        { job-id: job-id }
        (merge (unwrap-panic dispute)
          { client-evidence: (some evidence) }
        )
      )
      (if (is-eq (some user) (get assignee (unwrap-panic job)))
        (map-set disputes
          { job-id: job-id }
          (merge (unwrap-panic dispute)
            { freelancer-evidence: (some evidence) }
          )
        )
        false
      )
    )
    
    (ok true)
  )
)

;; Take on a dispute as an arbiter
(define-public (take-arbiter-role (job-id uint))
  (let (
    (arbiter tx-sender)
    (dispute (map-get? disputes { job-id: job-id }))
  )
    ;; Validate dispute exists and has no arbiter yet
    (asserts! (is-some dispute) ERR-NO-ACTIVE-DISPUTE)
    (asserts! (is-none (get arbiter (unwrap-panic dispute))) ERR-ALREADY-EXISTS)
    
    ;; Validate arbiter is approved
    (asserts! (is-arbiter arbiter) ERR-NOT-ARBITER)
    
    ;; Assign arbiter to dispute
    (map-set disputes
      { job-id: job-id }
      (merge (unwrap-panic dispute)
        { arbiter: (some arbiter) }
      )
    )
    
    (ok true)
  )
)

;; Resolve a dispute
(define-public (resolve-dispute 
  (job-id uint) 
  (client-percentage uint) 
  (freelancer-percentage uint) 
  (resolution-details (string-utf8 500)))
  (let (
    (arbiter tx-sender)
    (dispute (map-get? disputes { job-id: job-id }))
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate dispute exists and arbiter is assigned
    (asserts! (is-some dispute) ERR-NO-ACTIVE-DISPUTE)
    (asserts! (is-eq (some arbiter) (get arbiter (unwrap-panic dispute))) ERR-NOT-ARBITER)
    
    ;; Validate job exists and is disputed
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-DISPUTED) ERR-INVALID-STATUS)
    
    ;; Validate percentages add up to 100
    (asserts! (is-eq (+ client-percentage freelancer-percentage) u100) ERR-INVALID-STATUS)
    
    ;; Calculate payments
    (let (
      (client (get client (unwrap-panic job)))
      (assignee (unwrap! (get assignee (unwrap-panic job)) ERR-NOT-ASSIGNEE))
      (remaining (get remaining-amount (unwrap-panic job)))
      (client-payment (/ (* remaining client-percentage) u100))
      (freelancer-payment (/ (* remaining freelancer-percentage) u100))
      (platform-fee (calculate-fee remaining))
    )
      ;; Adjust payments to account for fee
      (let (
        (final-freelancer-payment (- freelancer-payment (/ (* freelancer-payment platform-fee) remaining)))
        (final-client-payment (- client-payment (/ (* client-payment platform-fee) remaining)))
      )
        ;; Transfer payments
        (if (> final-freelancer-payment u0)
          (try! (as-contract (stx-transfer? final-freelancer-payment tx-sender assignee)))
          true
        )
        
        (if (> final-client-payment u0)
          (try! (as-contract (stx-transfer? final-client-payment tx-sender client)))
          true
        )
        
        ;; Transfer fee to platform
        (try! (as-contract (stx-transfer? platform-fee tx-sender (var-get fee-address))))
        
        ;; Mark dispute as resolved
        (map-set disputes
          { job-id: job-id }
          (merge (unwrap-panic dispute)
            {
              resolved: true,
              resolution-details: (some resolution-details)
            }
          )
        )
        
        ;; Update job remaining amount and status
        (map-set jobs
          { job-id: job-id }
          (merge (unwrap-panic job)
            {
              remaining-amount: u0,
              status: STATUS-COMPLETED
            }
          )
        )
        
        ;; Update reputations based on outcome
        (if (> freelancer-percentage u50)
          (begin
            ;; Freelancer won dispute
            (let (
              (freelancer-profile (default-to 
                {
                  jobs-completed: u0,
                  jobs-posted: u0,
                  total-earned: u0,
                  total-paid: u0,
                  disputes-won: u0,
                  disputes-lost: u0,
                  reputation-score: u100,
                  created-at: block-height
                } 
                (map-get? user-profiles { user: assignee })))
              (client-profile (default-to 
                {
                  jobs-completed: u0,
                  jobs-posted: u0,
                  total-earned: u0,
                  total-paid: u0,
                  disputes-won: u0,
                  disputes-lost: u0,
                  reputation-score: u100,
                  created-at: block-height
                } 
                (map-get? user-profiles { user: client })))
            )
              (map-set user-profiles
                { user: assignee }
                (merge freelancer-profile {
                  disputes-won: (+ (get disputes-won freelancer-profile) u1),
                  reputation-score: (+ (get reputation-score freelancer-profile) u3)
                })
              )
              (map-set user-profiles
                { user: client }
                (merge client-profile {
                  disputes-lost: (+ (get disputes-lost client-profile) u1),
                  reputation-score: (if (> (get reputation-score client-profile) u3)
                    (- (get reputation-score client-profile) u3)
                    u1)
                })
              )
            )
          )
          (begin
            ;; Client won dispute
            (let (
              (freelancer-profile (default-to 
                {
                  jobs-completed: u0,
                  jobs-posted: u0,
                  total-earned: u0,
                  total-paid: u0,
                  disputes-won: u0,
                  disputes-lost: u0,
                  reputation-score: u100,
                  created-at: block-height
                } 
                (map-get? user-profiles { user: assignee })))
              (client-profile (default-to 
                {
                  jobs-completed: u0,
                  jobs-posted: u0,
                  total-earned: u0,
                  total-paid: u0,
                  disputes-won: u0,
                  disputes-lost: u0,
                  reputation-score: u100,
                  created-at: block-height
                } 
                (map-get? user-profiles { user: client })))
            )
              (map-set user-profiles
                { user: client }
                (merge client-profile {
                  disputes-won: (+ (get disputes-won client-profile) u1),
                  reputation-score: (+ (get reputation-score client-profile) u3)
                })
              )
              (map-set user-profiles
                { user: assignee }
                (merge freelancer-profile {
                  disputes-lost: (+ (get disputes-lost freelancer-profile) u1),
                  reputation-score: (if (> (get reputation-score freelancer-profile) u3)
                    (- (get reputation-score freelancer-profile) u3)
                    u1)
                })
              )
            )
          )
        )
        
        (ok true)
      )
    )
  )
)

;; Cancel a job (only if not yet assigned)
(define-public (cancel-job (job-id uint))
  (let (
    (client tx-sender)
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate job exists and is open
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (is-eq (get status (unwrap-panic job)) STATUS-OPEN) ERR-INVALID-STATUS)
    
    ;; Validate client is the job owner
    (asserts! (is-eq client (get client (unwrap-panic job))) ERR-NOT-CLIENT)
    
    ;; Return funds to client
    (try! (as-contract (stx-transfer? (get total-amount (unwrap-panic job)) tx-sender client)))
    
    ;; Update job status
    (map-set jobs
      { job-id: job-id }
      (merge (unwrap-panic job)
        { 
          status: STATUS-CANCELLED,
          remaining-amount: u0
        }
      )
    )
    
    (ok true)
  )
)

;; Add bonus payment to a job
(define-public (add-bonus-payment (job-id uint) (bonus-amount uint))
  (let (
    (client tx-sender)
    (job (map-get? jobs { job-id: job-id }))
  )
    ;; Validate job exists and is assigned or completed
    (asserts! (is-some job) ERR-JOB-NOT-FOUND)
    (asserts! (or 
      (is-eq (get status (unwrap-panic job)) STATUS-ASSIGNED)
      (is-eq (get status (unwrap-panic job)) STATUS-COMPLETED)
    ) ERR-INVALID-STATUS)
    
    ;; Validate client is the job owner
    (asserts! (is-eq client (get client (unwrap-panic job))) ERR-NOT-CLIENT)
    
    ;; Transfer bonus funds to contract
    (try! (stx-transfer? bonus-amount client (as-contract tx-sender)))
    
    ;; Update job total and remaining amounts
    (map-set jobs
      { job-id: job-id }
      (merge (unwrap-panic job)
        {
          total-amount: (+ (get total-amount (unwrap-panic job)) bonus-amount),
          remaining-amount: (+ (get remaining-amount (unwrap-panic job)) bonus-amount)
        }
      )
    )
    
    (ok true)
  )
)