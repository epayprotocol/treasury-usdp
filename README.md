# USDPTreasury – Treasury Management for USDP

Defined in [USDPTreasury.sol](USDPTreasury.sol). Deployment example in [TreasuryDeployment.sol](TreasuryDeployment.sol).

Manages USDT reserves, collateral allocation for USDP minting/burning, protocol fee collection and distribution, stability fund operations, time‑locked withdrawals, and emergency controls. Implements the treasury interface for stabilizer integration via [getCollateralValue()](USDPTreasury.sol:256), [hasAvailableCollateral(uint256)](USDPTreasury.sol:263), and [requestCollateralBacking(uint256)](USDPTreasury.sol:270).

## Table of Contents
- Overview
- Architecture and Roles
- Important State Variables
- Assets/Tokens Handling
- Core Functionality
- Events and Errors
- Security Model and Considerations
- Deployment and Initialization
- Integration Workflows
- Testing Notes and Assumptions
- Changelog
- License

## Overview
The USDPTreasury contract holds and manages USDT collateral that backs USDP. It tracks collateral, allocates/deallocates collateral for mint/burn operations, collects protocol fees and distributes them to the stability fund and governance/development, manages a stability fund with deployment caps, supports time‑locked withdrawals, and exposes emergency controls (pause/freeze and emergency withdrawals).

Key integrations:
- USDT token via [usdt](USDPTreasury.sol:142) and in-file [IERC20](USDPTreasury.sol:5).
- USDP supply reference via [usdpToken](USDPTreasury.sol:143) for backing ratio calculations.
- External stabilizer/manager contracts allowed by [onlyAuthorized()](USDPTreasury.sol:55).

## Architecture and Roles
- Ownership and governance
  - [owner](USDPTreasury.sol:29), [pendingOwner](USDPTreasury.sol:30)
  - [governance](USDPTreasury.sol:31)
  - [emergency](USDPTreasury.sol:32)
- Operators and multi‑sig
  - [treasuryOperators](USDPTreasury.sol:35) with required approvals [requiredApprovals](USDPTreasury.sol:38)
  - Approval/accounting mappings: [operatorApprovals](USDPTreasury.sol:36), [hasApproved](USDPTreasury.sol:37)
- Access modifiers (custom; not OpenZeppelin)
  - [onlyOwner()](USDPTreasury.sol:40) — owner‑only actions
  - [onlyGovernance()](USDPTreasury.sol:45) — governance or owner
  - [onlyEmergency()](USDPTreasury.sol:50) — emergency or owner
  - [onlyAuthorized()](USDPTreasury.sol:55) — owner, governance, [usdpStabilizer](USDPTreasury.sol:144), [usdpManager](USDPTreasury.sol:145), or any [treasuryOperators](USDPTreasury.sol:35)
- Reentrancy guard
  - [nonReentrant()](USDPTreasury.sol:73) using [_status](USDPTreasury.sol:71) (hand‑rolled, not OpenZeppelin)

## Important State Variables
- [collateralData](USDPTreasury.sol:149) (struct [CollateralData](USDPTreasury.sol:104)): tracks total reserves, allocated collateral, available collateral, emergency buffer, last update time.
- [feeStructure](USDPTreasury.sol:150) (struct [FeeStructure](USDPTreasury.sol:112)): fee bps (mint/burn/liquidation) and distribution shares (stability/governance/development).
- [stabilityFund](USDPTreasury.sol:151) (struct [StabilityFund](USDPTreasury.sol:121)): stability fund totals, deployed/reserve amounts, deployment cap, last deployment.
- [collectedFees](USDPTreasury.sol:154), [totalFeesCollected](USDPTreasury.sol:155), [totalFeesDistributed](USDPTreasury.sol:156): fee accounting.
- [withdrawalRequests](USDPTreasury.sol:159), [withdrawalDelay](USDPTreasury.sol:160): time‑locked withdrawals.
- [emergencyPaused](USDPTreasury.sol:163), [depositsEnabled](USDPTreasury.sol:164), [withdrawalsEnabled](USDPTreasury.sol:165): emergency/freeze flags.
- [BASIS_POINTS](USDPTreasury.sol:84), [MIN_COLLATERAL_RATIO](USDPTreasury.sol:86), [MAX_WITHDRAWAL_DELAY](USDPTreasury.sol:88): core constants.
- [DEFAULT_MINTING_FEE](USDPTreasury.sol:91), [DEFAULT_BURNING_FEE](USDPTreasury.sol:92), [DEFAULT_LIQUIDATION_FEE](USDPTreasury.sol:93), [STABILITY_FUND_SHARE](USDPTreasury.sol:96), [GOVERNANCE_SHARE](USDPTreasury.sol:97), [DEVELOPMENT_SHARE](USDPTreasury.sol:98): default parameters.
- [approvedYieldProtocols](USDPTreasury.sol:168), [totalYieldEarned](USDPTreasury.sol:169): placeholders for yield integration (N/A in current code).

## Assets/Tokens Handling
- Collateral token: USDT via [usdt](USDPTreasury.sol:142) and [IERC20](USDPTreasury.sol:5). Interactions: transferFrom/transfer for deposits, fee collection, stability fund operations, and withdrawals.
- USDP token: [usdpToken](USDPTreasury.sol:143) is read to compute collateral ratios in [calculateCollateralRatio()](USDPTreasury.sol:337) and [getTreasuryStatus()](USDPTreasury.sol:666). No USDP transfers are performed by this contract.
- Yield placeholders: [approvedYieldProtocols](USDPTreasury.sol:168), [totalYieldEarned](USDPTreasury.sol:169) — Not implemented in the current code.

## Core Functionality

### Interface and Collateral Backing (ITreasury)
- [getCollateralValue()](USDPTreasury.sol:256)
  - Returns current collateral reserves (USDT) from [collateralData](USDPTreasury.sol:149). No access restriction.
  - Reverts: N/A. Events: N/A.
- [hasAvailableCollateral(uint256)](USDPTreasury.sol:263)
  - Returns whether [collateralData.availableCollateral](USDPTreasury.sol:149) >= amount. No access restriction.
  - Reverts: N/A. Events: N/A.
- [requestCollateralBacking(uint256)](USDPTreasury.sol:270)
  - Allocates collateral for a minting operation. Effects: increments [collateralData.allocatedCollateral](USDPTreasury.sol:149) and decrements [collateralData.availableCollateral](USDPTreasury.sol:149).
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55), [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "EMERGENCY_PAUSED", "INSUFFICIENT_AVAILABLE_COLLATERAL".
  - Events: [CollateralAllocated(uint256,uint256)](USDPTreasury.sol:176).

### Collateral Management
- [addCollateral(uint256)](USDPTreasury.sol:288)
  - Anyone can deposit USDT via transferFrom. Updates reserves and availability, timestamps last update.
  - Auth: public; [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "EMERGENCY_PAUSED", "DEPOSITS_DISABLED", "INVALID_AMOUNT".
  - Events: [CollateralAdded(address,uint256,uint256)](USDPTreasury.sol:175).
- [removeCollateral(uint256,address,string)](USDPTreasury.sol:308)
  - Multi‑sig protected removal. If required approvals not met, records an approval and returns. Once met, reduces reserves/availability, enforces backing ratio, then transfers USDT to recipient.
  - Auth: multi‑sig via [_hasRequiredApprovals(bytes32)](USDPTreasury.sol:740) and [_recordApproval(bytes32)](USDPTreasury.sol:727); no direct modifier.
  - Reverts on: "WITHDRAWALS_DISABLED", "INSUFFICIENT_AVAILABLE_COLLATERAL", "COLLATERAL_RATIO_VIOLATION". During approval recording: "NOT_OPERATOR" or "ALREADY_APPROVED".
  - Events: [OperationExecuted(bytes32,string)](USDPTreasury.sol:193).
  - Notes: Operation hash includes block.timestamp; see Security section regarding approval accumulation.
- [calculateCollateralRatio()](USDPTreasury.sol:337)
  - Computes reserves/USDP totalSupply ratio with 18 decimals; returns max uint if [usdpToken](USDPTreasury.sol:143) is unset or totalSupply == 0.
- [verifyBackingRatio()](USDPTreasury.sol:348)
  - Returns whether current ratio >= [MIN_COLLATERAL_RATIO](USDPTreasury.sol:86).
- [allocateForMinting(uint256)](USDPTreasury.sol:354)
  - Same allocation as requestCollateralBacking but explicit; for authorized callers.
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55), [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "INSUFFICIENT_AVAILABLE_COLLATERAL".
  - Events: [CollateralAllocated(uint256,uint256)](USDPTreasury.sol:176).
- [deallocateFromBurning(uint256)](USDPTreasury.sol:365)
  - Deallocates collateral post‑burn and returns it to availability.
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55), [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "INSUFFICIENT_ALLOCATED_COLLATERAL".
  - Events: [CollateralDeallocated(uint256,uint256)](USDPTreasury.sol:177).

### Protocol Fee Management
- [collectFees(address,uint256,string)](USDPTreasury.sol:382)
  - Pulls USDT from source, accumulates [collectedFees](USDPTreasury.sol:154), and increments [totalFeesCollected](USDPTreasury.sol:155).
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55), [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "INVALID_FEE_AMOUNT".
  - Events: [FeeCollected(address,uint256,string)](USDPTreasury.sol:180).
- [distributeFees()](USDPTreasury.sol:396)
  - Computes undistributed fees and splits by [feeStructure](USDPTreasury.sol:150).
  - Transfers governance share to [governance](USDPTreasury.sol:31), development share to [owner](USDPTreasury.sol:29), and credits the stability share to [stabilityFund](USDPTreasury.sol:151).
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55), [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "NO_FEES_TO_DISTRIBUTE".
  - Events: [FeeDistributed(uint256,uint256,uint256)](USDPTreasury.sol:181).
- [updateFeeStructure(FeeStructure)](USDPTreasury.sol:424)
  - Updates [feeStructure](USDPTreasury.sol:150) after [_validateFeeStructure(FeeStructure)](USDPTreasury.sol:721) passes (distribution shares must sum to [BASIS_POINTS](USDPTreasury.sol:84)).
  - Auth: [onlyGovernance()](USDPTreasury.sol:45).
  - Reverts on: "INVALID_FEE_STRUCTURE".
  - Events: [FeeStructureUpdated(address)](USDPTreasury.sol:182).
- [getFee(uint256)](USDPTreasury.sol:434)
  - 0=mint, 1=burn, 2=liquidate; returns bp from current [feeStructure](USDPTreasury.sol:150).
- [getFeeInformation()](USDPTreasury.sol:691)
  - Returns the current [FeeStructure](USDPTreasury.sol:112).

### Stability Fund Operations
- [deployStabilityFunds(uint256,address)](USDPTreasury.sol:448)
  - Deploys funds if available and within deployment cap configured in [stabilityFund](USDPTreasury.sol:151). Updates deployed amount and timestamp, then transfers USDT.
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55), [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "EMERGENCY_PAUSED", "INSUFFICIENT_STABILITY_FUNDS", "EXCEEDS_MAX_DEPLOYMENT".
  - Events: [StabilityFundDeployed(uint256,uint256)](USDPTreasury.sol:184).
- [replenishStabilityFund(uint256)](USDPTreasury.sol:463)
  - Returns funds to the treasury via transferFrom; reduces deployed amount. Any excess over the previously deployed amount is added to the stability fund's total.
  - Auth: public; [nonReentrant()](USDPTreasury.sol:73).
  - Events: [StabilityFundReplenished(uint256,uint256)](USDPTreasury.sol:185).
- [activateEmergencyFund(uint256,string)](USDPTreasury.sol:479)
  - Moves from reserve funds to deployed funds.
  - Auth: [onlyEmergency()](USDPTreasury.sol:50).
  - Reverts on: "INSUFFICIENT_RESERVE_FUNDS".
  - Events: [EmergencyFundActivated(uint256,string)](USDPTreasury.sol:186).
  - Notes: No function currently funds reserveFunds; consider governance flows to populate it.
- [setMaxDeployment(uint256)](USDPTreasury.sol:490)
  - Sets maximum deployment cap used by stability fund operations.
  - Auth: [onlyGovernance()](USDPTreasury.sol:45).
- [getStabilityFundStatus()](USDPTreasury.sol:697)
  - Returns current [StabilityFund](USDPTreasury.sol:121) snapshot.

### Emergency Controls
- [emergencyPause()](USDPTreasury.sol:499)
  - Sets [emergencyPaused](USDPTreasury.sol:163)=true.
  - Auth: [onlyEmergency()](USDPTreasury.sol:50).
  - Events: [EmergencyPaused(uint256)](USDPTreasury.sol:195).
- [emergencyUnpause()](USDPTreasury.sol:505)
  - Sets [emergencyPaused](USDPTreasury.sol:163)=false.
  - Auth: [onlyOwner()](USDPTreasury.sol:40).
  - Events: [EmergencyUnpaused(uint256)](USDPTreasury.sol:196).
- [emergencyWithdraw(uint256,address,string)](USDPTreasury.sol:514)
  - Multi‑sig protected. Transfers requested USDT directly to target after approvals.
  - Auth: multi‑sig via [_hasRequiredApprovals(bytes32)](USDPTreasury.sol:740) / [_recordApproval(bytes32)](USDPTreasury.sol:727).
  - Reverts on: "INSUFFICIENT_BALANCE". During approval recording: "NOT_OPERATOR" or "ALREADY_APPROVED".
  - Events: [EmergencyWithdrawal(address,uint256,string)](USDPTreasury.sol:178), [OperationExecuted(bytes32,string)](USDPTreasury.sol:193).
- [freezeOperations(bool,bool)](USDPTreasury.sol:534)
  - Toggles [depositsEnabled](USDPTreasury.sol:164) and [withdrawalsEnabled](USDPTreasury.sol:165).
  - Auth: [onlyEmergency()](USDPTreasury.sol:50).
  - Notes: [executeWithdrawal(bytes32)](USDPTreasury.sol:564) does not check withdrawalsEnabled; time‑locked withdrawals remain executable while frozen.

### Time‑Locked Withdrawals
- [requestWithdrawal(uint256,string)](USDPTreasury.sol:547)
  - Creates a [WithdrawalRequest](USDPTreasury.sol:129) keyed by requestId and emits an event.
  - Auth: [onlyAuthorized()](USDPTreasury.sol:55).
  - Events: [WithdrawalRequested(bytes32,address,uint256)](USDPTreasury.sol:188).
- [executeWithdrawal(bytes32)](USDPTreasury.sol:564)
  - After [withdrawalDelay](USDPTreasury.sol:160), transfers USDT to original requester and reduces reserves/availability.
  - Auth: public; [nonReentrant()](USDPTreasury.sol:73).
  - Reverts on: "ALREADY_EXECUTED", "WITHDRAWAL_NOT_READY", "INSUFFICIENT_COLLATERAL".
  - Events: [WithdrawalExecuted(bytes32,uint256)](USDPTreasury.sol:189).
- [setWithdrawalDelay(uint256)](USDPTreasury.sol:650)
  - Caps delay by [MAX_WITHDRAWAL_DELAY](USDPTreasury.sol:88).
  - Auth: [onlyGovernance()](USDPTreasury.sol:45).

### Multi‑Signature Administration
- [addTreasuryOperator(address)](USDPTreasury.sol:585), [removeTreasuryOperator(address)](USDPTreasury.sol:591)
  - Manage operator set eligible to approve operations.
  - Auth: [onlyOwner()](USDPTreasury.sol:40).
- [setRequiredApprovals(uint256)](USDPTreasury.sol:597)
  - Sets [requiredApprovals](USDPTreasury.sol:38) (>0).
  - Auth: [onlyOwner()](USDPTreasury.sol:40).
- Internal helpers: [_recordApproval(bytes32)](USDPTreasury.sol:727), [_hasRequiredApprovals(bytes32)](USDPTreasury.sol:740), [_clearApprovals(bytes32)](USDPTreasury.sol:746).

### Administrative / Configuration
- [setEcosystemContracts(address,address,address,address)](USDPTreasury.sol:611)
  - Sets [usdpToken](USDPTreasury.sol:143), [usdpStabilizer](USDPTreasury.sol:144), [usdpManager](USDPTreasury.sol:145), [usdpOracle](USDPTreasury.sol:146).
  - Auth: [onlyOwner()](USDPTreasury.sol:40).
- [updateGovernance(address)](USDPTreasury.sol:625)
  - Updates [governance](USDPTreasury.sol:31).
  - Auth: [onlyOwner()](USDPTreasury.sol:40).
  - Events: [GovernanceUpdated(address,address)](USDPTreasury.sol:197).
- [transferOwnership(address)](USDPTreasury.sol:634), [acceptOwnership()](USDPTreasury.sol:640)
  - Two‑step ownership transfer ([owner](USDPTreasury.sol:29) -> [pendingOwner](USDPTreasury.sol:30)).
  - Auth: transfer by [onlyOwner()](USDPTreasury.sol:40); accept by [pendingOwner](USDPTreasury.sol:30).
  - Events: [OwnershipTransferred(address,address)](USDPTreasury.sol:198).

### View / Status
- [getTreasuryStatus()](USDPTreasury.sol:666)
  - Aggregated snapshot: reserves, allocated, available, ratio, stability fund balance, and pause state.

## Events and Errors
Events
- [CollateralAdded(address,uint256,uint256)](USDPTreasury.sol:175) — deposit recorded
- [CollateralAllocated(uint256,uint256)](USDPTreasury.sol:176); [CollateralDeallocated(uint256,uint256)](USDPTreasury.sol:177)
- [EmergencyWithdrawal(address,uint256,string)](USDPTreasury.sol:178)
- [FeeCollected(address,uint256,string)](USDPTreasury.sol:180); [FeeDistributed(uint256,uint256,uint256)](USDPTreasury.sol:181); [FeeStructureUpdated(address)](USDPTreasury.sol:182)
- [StabilityFundDeployed(uint256,uint256)](USDPTreasury.sol:184); [StabilityFundReplenished(uint256,uint256)](USDPTreasury.sol:185); [EmergencyFundActivated(uint256,string)](USDPTreasury.sol:186)
- [WithdrawalRequested(bytes32,address,uint256)](USDPTreasury.sol:188); [WithdrawalExecuted(bytes32,uint256)](USDPTreasury.sol:189); [WithdrawalCancelled(bytes32)](USDPTreasury.sol:190) — Not emitted in current code
- [OperationApproved(bytes32,address,uint256)](USDPTreasury.sol:192); [OperationExecuted(bytes32,string)](USDPTreasury.sol:193)
- [EmergencyPaused(uint256)](USDPTreasury.sol:195); [EmergencyUnpaused(uint256)](USDPTreasury.sol:196)
- [GovernanceUpdated(address,address)](USDPTreasury.sol:197); [OwnershipTransferred(address,address)](USDPTreasury.sol:198)

Custom errors (declared but not used; reverts use string messages)
- [InsufficientCollateral()](USDPTreasury.sol:204)
- [InvalidCollateralRatio()](USDPTreasury.sol:205)
- [InsufficientStabilityFunds()](USDPTreasury.sol:206)
- [WithdrawalNotReady()](USDPTreasury.sol:207)
- [InvalidFeeStructure()](USDPTreasury.sol:208)
- [EmergencyPausedError()](USDPTreasury.sol:209)
- [UnauthorizedAccess()](USDPTreasury.sol:210)
- [InvalidOperation()](USDPTreasury.sol:211)
- [InsufficientApprovals()](USDPTreasury.sol:212)

## Security Model and Considerations
- Access control: Custom roles via [onlyOwner()](USDPTreasury.sol:40), [onlyGovernance()](USDPTreasury.sol:45), [onlyEmergency()](USDPTreasury.sol:50), and [onlyAuthorized()](USDPTreasury.sol:55). No OpenZeppelin AccessControl/Ownable is used.
- Reentrancy: [nonReentrant()](USDPTreasury.sol:73) protects many state‑changing functions. Notably, [removeCollateral(uint256,address,string)](USDPTreasury.sol:308) and [emergencyWithdraw(uint256,address,string)](USDPTreasury.sol:514) do not use the modifier but follow checks‑effects‑interactions.
- Pausability: [emergencyPaused](USDPTreasury.sol:163) gates [addCollateral(uint256)](USDPTreasury.sol:288), [requestCollateralBacking(uint256)](USDPTreasury.sol:270), and [deployStabilityFunds(uint256,address)](USDPTreasury.sol:448). [removeCollateral(uint256,address,string)](USDPTreasury.sol:308) is controlled by [withdrawalsEnabled](USDPTreasury.sol:165) instead. [executeWithdrawal(bytes32)](USDPTreasury.sol:564) is not blocked by freezes.
- Backing ratio invariant: [MIN_COLLATERAL_RATIO](USDPTreasury.sol:86) enforced on collateral removals via [_verifyCollateralRatio(uint256)](USDPTreasury.sol:708).
- Fee distribution invariant: [_validateFeeStructure(FeeStructure)](USDPTreasury.sol:721) requires distribution shares sum to [BASIS_POINTS](USDPTreasury.sol:84).
- Multi‑sig design caution:
  - Operation hash includes block.timestamp in both [removeCollateral(uint256,address,string)](USDPTreasury.sol:308) and [emergencyWithdraw(uint256,address,string)](USDPTreasury.sol:514): approvals are tracked under [operatorApprovals](USDPTreasury.sol:36) by this hash via [_recordApproval(bytes32)](USDPTreasury.sol:727). Because block.timestamp changes each call, approvals are unlikely to accumulate across transactions, preventing execution from ever reaching the required threshold in normal conditions.
  - Consider deriving operationHash without timestamp and/or introducing explicit nonces to allow approvals to aggregate safely.
- ERC20 safety: Transfers do not check return values; behavior assumes standard ERC20 semantics.
- Unused/placeholder fields: [stabilityFund.reserveFunds](USDPTreasury.sol:121) is never funded by current functions; [EMERGENCY_FUND_THRESHOLD](USDPTreasury.sol:87), [approvedYieldProtocols](USDPTreasury.sol:168), and [totalYieldEarned](USDPTreasury.sol:169) are present but not actively managed.
- Upgradeability: Non‑upgradeable. Uses a [constructor(address,address,address,address)](USDPTreasury.sol:218) and immutable [usdt](USDPTreasury.sol:142). No proxy pattern in this contract.
- External dependencies: No OpenZeppelin imports; uses in‑file [IERC20](USDPTreasury.sol:5) and custom modifiers/guards.

## Deployment and Initialization
- Constructor: [constructor(address,address,address,address)](USDPTreasury.sol:218)
  - Sets [owner](USDPTreasury.sol:29), [usdt](USDPTreasury.sol:142), [governance](USDPTreasury.sol:31), [emergency](USDPTreasury.sol:32).
  - Initializes [feeStructure](USDPTreasury.sol:150) with defaults: [DEFAULT_MINTING_FEE](USDPTreasury.sol:91), [DEFAULT_BURNING_FEE](USDPTreasury.sol:92), [DEFAULT_LIQUIDATION_FEE](USDPTreasury.sol:93), [STABILITY_FUND_SHARE](USDPTreasury.sol:96), [GOVERNANCE_SHARE](USDPTreasury.sol:97), [DEVELOPMENT_SHARE](USDPTreasury.sol:98). Emits [OwnershipTransferred(address,address)](USDPTreasury.sol:198).
- Example deployment helper (illustrative only): [deployTreasury(DeploymentConfig)](TreasuryDeployment.sol:43)
  - Deploys [USDPTreasuryProxy](TreasuryDeployment.sol:153) (stub implementation). This proxy does not wire a real USDPTreasury and is for demonstration.
- Example post‑deploy setup: [initializeEcosystem(DeploymentConfig)](TreasuryDeployment.sol:80)
  - Calls [ITreasuryAdmin.setEcosystemContracts(address,address,address,address)](TreasuryDeployment.sol:183).
  - Adds operators via [ITreasuryAdmin.addTreasuryOperator(address)](TreasuryDeployment.sol:190).
- Validation helper: [validateDeployment()](TreasuryDeployment.sol:116), [getDeploymentSummary()](TreasuryDeployment.sol:140).

## Integration Workflows
- Initial setup (owner)
  - [setEcosystemContracts(address,address,address,address)](USDPTreasury.sol:611)
  - [addTreasuryOperator(address)](USDPTreasury.sol:585) for governance and emergency (see example script), then [setRequiredApprovals(uint256)](USDPTreasury.sol:597)
  - Optionally [setWithdrawalDelay(uint256)](USDPTreasury.sol:650) and [setMaxDeployment(uint256)](USDPTreasury.sol:490)
- Deposits
  - Users call [addCollateral(uint256)](USDPTreasury.sol:288) after approving USDT to treasury.
- Mint flow (authorized)
  - [requestCollateralBacking(uint256)](USDPTreasury.sol:270) and/or [allocateForMinting(uint256)](USDPTreasury.sol:354)
- Burn flow (authorized)
  - [deallocateFromBurning(uint256)](USDPTreasury.sol:365)
- Fees
  - [collectFees(address,uint256,string)](USDPTreasury.sol:382) then periodic [distributeFees()](USDPTreasury.sol:396)
- Time‑locked withdrawal
  - [requestWithdrawal(uint256,string)](USDPTreasury.sol:547) -> wait [withdrawalDelay](USDPTreasury.sol:160) -> [executeWithdrawal(bytes32)](USDPTreasury.sol:564)
- Emergency
  - [emergencyPause()](USDPTreasury.sol:499) / [emergencyUnpause()](USDPTreasury.sol:505); [freezeOperations(bool,bool)](USDPTreasury.sol:534)
  - Multi‑sig emergency payout: [emergencyWithdraw(uint256,address,string)](USDPTreasury.sol:514) (see Security regarding approval hash)

## Testing Notes and Assumptions
- Verify multi‑sig approval accumulation: due to timestamp in operation hash, approvals likely do not aggregate; tests should demonstrate the issue and/or a fix.
- Confirm collateral ratio enforcement on [removeCollateral(uint256,address,string)](USDPTreasury.sol:308) across various USDP supplies (unset token, zero supply, non‑zero).
- Exercise pausability/freeze switches and ensure correct gating (notably [executeWithdrawal(bytes32)](USDPTreasury.sol:564) behavior under freeze).
- Validate fee distribution math sums to [BASIS_POINTS](USDPTreasury.sol:84) and events correctness.
- ERC20 behavior assumptions: functions do not check boolean returns on transfer/transferFrom; using standard‑compliant USDT is assumed.
- Emergency fund path: consider populating [stabilityFund.reserveFunds](USDPTreasury.sol:121) in tests or marking as N/A.

## Changelog
- v1 – initial README

## License
Not specified (SPDX headers in sources declare MIT).