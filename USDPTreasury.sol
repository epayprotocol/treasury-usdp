// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Simple ERC20 interface for treasury operations
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev Treasury interface for USDPStabilizer integration
interface ITreasury {
    function getCollateralValue() external view returns (uint256);
    function hasAvailableCollateral(uint256 amount) external view returns (bool);
    function requestCollateralBacking(uint256 amount) external returns (bool);
}

/// @title USDP Treasury - Comprehensive Financial Management Contract
/// @notice Manages collateral reserves, protocol fees, and stability fund operations for USDP ecosystem
/// @dev Implements ITreasury interface for USDPStabilizer integration with multi-signature security
contract USDPTreasury is ITreasury {
    /*//////////////////////////////////////////////////////////////
                                OWNERSHIP & ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/
    
    address public owner;
    address public pendingOwner;
    address public governance;
    address public emergency;
    
    // Multi-signature requirements
    mapping(address => bool) public treasuryOperators;
    mapping(bytes32 => uint256) public operatorApprovals; // operationHash => approvalCount
    mapping(bytes32 => mapping(address => bool)) public hasApproved; // operationHash => operator => approved
    uint256 public requiredApprovals = 2; // Minimum operators required for treasury operations
    
    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED");
        _;
    }
    
    modifier onlyGovernance() {
        require(msg.sender == governance || msg.sender == owner, "UNAUTHORIZED_GOVERNANCE");
        _;
    }
    
    modifier onlyEmergency() {
        require(msg.sender == emergency || msg.sender == owner, "UNAUTHORIZED_EMERGENCY");
        _;
    }
    
    modifier onlyAuthorized() {
        require(
            msg.sender == owner || 
            msg.sender == governance || 
            msg.sender == usdpStabilizer || 
            msg.sender == usdpManager ||
            treasuryOperators[msg.sender], 
            "UNAUTHORIZED"
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/
    
    uint256 private _status = 1;
    
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DECIMALS = 18;
    uint256 public constant MIN_COLLATERAL_RATIO = 1e18; // 100% - 1:1 backing
    uint256 public constant EMERGENCY_FUND_THRESHOLD = 500; // 5% in basis points
    uint256 public constant MAX_WITHDRAWAL_DELAY = 7 days;
    
    // Default fee structure (in basis points)
    uint256 public constant DEFAULT_MINTING_FEE = 10;    // 0.1%
    uint256 public constant DEFAULT_BURNING_FEE = 5;     // 0.05%
    uint256 public constant DEFAULT_LIQUIDATION_FEE = 500; // 5%
    
    // Default fee distribution (in basis points)
    uint256 public constant STABILITY_FUND_SHARE = 7000;  // 70%
    uint256 public constant GOVERNANCE_SHARE = 2000;      // 20%
    uint256 public constant DEVELOPMENT_SHARE = 1000;     // 10%

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    
    struct CollateralData {
        uint256 totalReserves;        // Total USDT reserves
        uint256 allocatedCollateral;  // Collateral allocated for backing
        uint256 availableCollateral;  // Available for new minting
        uint256 emergencyBuffer;      // Emergency fund buffer
        uint256 lastUpdateTime;       // Last collateral update timestamp
    }
    
    struct FeeStructure {
        uint256 mintingFee;       // Fee for minting operations (BP)
        uint256 burningFee;       // Fee for burning operations (BP)
        uint256 liquidationFee;   // Fee for liquidation operations (BP)
        uint256 stabilityShare;   // Share to stability fund (BP)
        uint256 governanceShare;  // Share to governance (BP)
        uint256 developmentShare; // Share to development (BP)
    }
    
    struct StabilityFund {
        uint256 totalFunds;       // Total stability fund balance
        uint256 deployedFunds;    // Currently deployed for stabilization
        uint256 reserveFunds;     // Reserve funds for emergencies
        uint256 maxDeployment;    // Maximum deployable at once
        uint256 lastDeployment;   // Last deployment timestamp
    }
    
    struct WithdrawalRequest {
        address requester;
        uint256 amount;
        uint256 requestTime;
        bool executed;
        string reason;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    // Core ecosystem contracts
    IERC20 public immutable usdt;
    address public usdpToken;
    address public usdpStabilizer;
    address public usdpManager;
    address public usdpOracle;
    
    // Treasury data
    CollateralData public collateralData;
    FeeStructure public feeStructure;
    StabilityFund public stabilityFund;
    
    // Fee tracking
    mapping(address => uint256) public collectedFees; // contract => total fees collected
    uint256 public totalFeesCollected;
    uint256 public totalFeesDistributed;
    
    // Withdrawal management
    mapping(bytes32 => WithdrawalRequest) public withdrawalRequests;
    uint256 public withdrawalDelay = 24 hours; // Time-lock for non-operational withdrawals
    
    // Emergency controls
    bool public emergencyPaused;
    bool public depositsEnabled = true;
    bool public withdrawalsEnabled = true;
    
    // Yield generation
    mapping(address => bool) public approvedYieldProtocols;
    uint256 public totalYieldEarned;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event CollateralAdded(address indexed from, uint256 amount, uint256 newTotal);
    event CollateralAllocated(uint256 amount, uint256 remainingAvailable);
    event CollateralDeallocated(uint256 amount, uint256 newAvailable);
    event EmergencyWithdrawal(address indexed to, uint256 amount, string reason);
    
    event FeeCollected(address indexed from, uint256 amount, string feeType);
    event FeeDistributed(uint256 stabilityAmount, uint256 governanceAmount, uint256 developmentAmount);
    event FeeStructureUpdated(address indexed updater);
    
    event StabilityFundDeployed(uint256 amount, uint256 totalDeployed);
    event StabilityFundReplenished(uint256 amount, uint256 newTotal);
    event EmergencyFundActivated(uint256 amount, string reason);
    
    event WithdrawalRequested(bytes32 indexed requestId, address indexed requester, uint256 amount);
    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);
    event WithdrawalCancelled(bytes32 indexed requestId);
    
    event OperationApproved(bytes32 indexed operationHash, address indexed operator, uint256 totalApprovals);
    event OperationExecuted(bytes32 indexed operationHash, string operation);
    
    event EmergencyPaused(uint256 timestamp);
    event EmergencyUnpaused(uint256 timestamp);
    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error InsufficientCollateral();
    error InvalidCollateralRatio();
    error InsufficientStabilityFunds();
    error WithdrawalNotReady();
    error InvalidFeeStructure();
    error EmergencyPausedError();
    error UnauthorizedAccess();
    error InvalidOperation();
    error InsufficientApprovals();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    constructor(
        address _owner,
        address _usdt,
        address _governance,
        address _emergency
    ) {
        require(_owner != address(0), "INVALID_OWNER");
        require(_usdt != address(0), "INVALID_USDT");
        require(_governance != address(0), "INVALID_GOVERNANCE");
        require(_emergency != address(0), "INVALID_EMERGENCY");
        
        owner = _owner;
        usdt = IERC20(_usdt);
        governance = _governance;
        emergency = _emergency;
        
        // Initialize default fee structure
        feeStructure = FeeStructure({
            mintingFee: DEFAULT_MINTING_FEE,
            burningFee: DEFAULT_BURNING_FEE,
            liquidationFee: DEFAULT_LIQUIDATION_FEE,
            stabilityShare: STABILITY_FUND_SHARE,
            governanceShare: GOVERNANCE_SHARE,
            developmentShare: DEVELOPMENT_SHARE
        });
        
        // Initialize collateral data
        collateralData.lastUpdateTime = block.timestamp;
        
        emit OwnershipTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                        ITTREASURY INTERFACE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Get total collateral value (implements ITreasury)
    /// @return Total USDT collateral value
    function getCollateralValue() external view returns (uint256) {
        return collateralData.totalReserves;
    }
    
    /// @notice Check if collateral is available for backing (implements ITreasury)
    /// @param amount Amount to check for availability
    /// @return True if sufficient collateral is available
    function hasAvailableCollateral(uint256 amount) external view returns (bool) {
        return collateralData.availableCollateral >= amount;
    }
    
    /// @notice Request collateral backing for minting (implements ITreasury)
    /// @param amount Amount of collateral to allocate
    /// @return True if collateral was successfully allocated
    function requestCollateralBacking(uint256 amount) external onlyAuthorized nonReentrant returns (bool) {
        require(!emergencyPaused, "EMERGENCY_PAUSED");
        require(collateralData.availableCollateral >= amount, "INSUFFICIENT_AVAILABLE_COLLATERAL");
        
        // Allocate collateral
        collateralData.allocatedCollateral += amount;
        collateralData.availableCollateral -= amount;
        
        emit CollateralAllocated(amount, collateralData.availableCollateral);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE COLLATERAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Add USDT collateral to treasury reserves
    /// @param amount Amount of USDT to deposit
    function addCollateral(uint256 amount) external nonReentrant {
        require(!emergencyPaused, "EMERGENCY_PAUSED");
        require(depositsEnabled, "DEPOSITS_DISABLED");
        require(amount > 0, "INVALID_AMOUNT");
        
        // Transfer USDT from sender
        usdt.transferFrom(msg.sender, address(this), amount);
        
        // Update collateral data
        collateralData.totalReserves += amount;
        collateralData.availableCollateral += amount;
        collateralData.lastUpdateTime = block.timestamp;
        
        emit CollateralAdded(msg.sender, amount, collateralData.totalReserves);
    }
    
    /// @notice Remove collateral from treasury (multi-sig required)
    /// @param amount Amount to remove
    /// @param to Recipient address
    /// @param reason Reason for removal
    function removeCollateral(uint256 amount, address to, string calldata reason) external {
        bytes32 operationHash = keccak256(abi.encodePacked("removeCollateral", amount, to, reason, block.timestamp));
        
        if (!_hasRequiredApprovals(operationHash)) {
            _recordApproval(operationHash);
            return;
        }
        
        require(withdrawalsEnabled, "WITHDRAWALS_DISABLED");
        require(amount <= collateralData.availableCollateral, "INSUFFICIENT_AVAILABLE_COLLATERAL");
        
        // Verify collateral ratio is maintained
        uint256 newTotal = collateralData.totalReserves - amount;
        require(_verifyCollateralRatio(newTotal), "COLLATERAL_RATIO_VIOLATION");
        
        // Update state
        collateralData.totalReserves -= amount;
        collateralData.availableCollateral -= amount;
        collateralData.lastUpdateTime = block.timestamp;
        
        // Transfer USDT
        usdt.transfer(to, amount);
        
        emit OperationExecuted(operationHash, "removeCollateral");
        _clearApprovals(operationHash);
    }
    
    /// @notice Calculate current collateral ratio
    /// @return Current collateral ratio (with 18 decimals)
    function calculateCollateralRatio() external view returns (uint256) {
        if (usdpToken == address(0)) return type(uint256).max;
        
        uint256 totalSupply = IERC20(usdpToken).totalSupply();
        if (totalSupply == 0) return type(uint256).max;
        
        return (collateralData.totalReserves * 1e18) / totalSupply;
    }
    
    /// @notice Verify if backing ratio is maintained
    /// @return True if ratio is above minimum threshold
    function verifyBackingRatio() external view returns (bool) {
        return _verifyCollateralRatio(collateralData.totalReserves);
    }
    
    /// @notice Allocate collateral for specific minting operation
    /// @param amount Amount to allocate
    function allocateForMinting(uint256 amount) external onlyAuthorized nonReentrant {
        require(collateralData.availableCollateral >= amount, "INSUFFICIENT_AVAILABLE_COLLATERAL");
        
        collateralData.allocatedCollateral += amount;
        collateralData.availableCollateral -= amount;
        
        emit CollateralAllocated(amount, collateralData.availableCollateral);
    }
    
    /// @notice Deallocate collateral after burning operation
    /// @param amount Amount to deallocate
    function deallocateFromBurning(uint256 amount) external onlyAuthorized nonReentrant {
        require(collateralData.allocatedCollateral >= amount, "INSUFFICIENT_ALLOCATED_COLLATERAL");
        
        collateralData.allocatedCollateral -= amount;
        collateralData.availableCollateral += amount;
        
        emit CollateralDeallocated(amount, collateralData.availableCollateral);
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Collect protocol fees from operations
    /// @param from Source of the fee
    /// @param amount Fee amount
    /// @param feeType Type of fee (minting, burning, liquidation)
    function collectFees(address from, uint256 amount, string calldata feeType) external onlyAuthorized nonReentrant {
        require(amount > 0, "INVALID_FEE_AMOUNT");
        
        // Transfer fee from source
        usdt.transferFrom(from, address(this), amount);
        
        // Update tracking
        collectedFees[from] += amount;
        totalFeesCollected += amount;
        
        emit FeeCollected(from, amount, feeType);
    }
    
    /// @notice Distribute collected fees according to fee structure
    function distributeFees() external onlyAuthorized nonReentrant {
        uint256 availableFees = totalFeesCollected - totalFeesDistributed;
        require(availableFees > 0, "NO_FEES_TO_DISTRIBUTE");
        
        // Calculate distribution amounts
        uint256 stabilityAmount = (availableFees * feeStructure.stabilityShare) / BASIS_POINTS;
        uint256 governanceAmount = (availableFees * feeStructure.governanceShare) / BASIS_POINTS;
        uint256 developmentAmount = (availableFees * feeStructure.developmentShare) / BASIS_POINTS;
        
        // Add to stability fund
        stabilityFund.totalFunds += stabilityAmount;
        
        // Transfer to governance and development
        if (governanceAmount > 0) {
            usdt.transfer(governance, governanceAmount);
        }
        
        if (developmentAmount > 0) {
            usdt.transfer(owner, developmentAmount); // Development funds go to owner
        }
        
        totalFeesDistributed += availableFees;
        
        emit FeeDistributed(stabilityAmount, governanceAmount, developmentAmount);
    }
    
    /// @notice Update fee structure (governance only)
    /// @param newFeeStructure New fee configuration
    function updateFeeStructure(FeeStructure calldata newFeeStructure) external onlyGovernance {
        require(_validateFeeStructure(newFeeStructure), "INVALID_FEE_STRUCTURE");
        
        feeStructure = newFeeStructure;
        emit FeeStructureUpdated(msg.sender);
    }
    
    /// @notice Get current fee for operation type
    /// @param operationType Type of operation (0=mint, 1=burn, 2=liquidate)
    /// @return Fee in basis points
    function getFee(uint256 operationType) external view returns (uint256) {
        if (operationType == 0) return feeStructure.mintingFee;
        if (operationType == 1) return feeStructure.burningFee;
        if (operationType == 2) return feeStructure.liquidationFee;
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        STABILITY FUND OPERATIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Deploy stability funds for market operations
    /// @param amount Amount to deploy
    /// @param recipient Recipient of the funds
    function deployStabilityFunds(uint256 amount, address recipient) external onlyAuthorized nonReentrant {
        require(!emergencyPaused, "EMERGENCY_PAUSED");
        require(amount <= stabilityFund.totalFunds - stabilityFund.deployedFunds, "INSUFFICIENT_STABILITY_FUNDS");
        require(amount <= stabilityFund.maxDeployment, "EXCEEDS_MAX_DEPLOYMENT");
        
        stabilityFund.deployedFunds += amount;
        stabilityFund.lastDeployment = block.timestamp;
        
        usdt.transfer(recipient, amount);
        
        emit StabilityFundDeployed(amount, stabilityFund.deployedFunds);
    }
    
    /// @notice Replenish stability fund after operations
    /// @param amount Amount being returned
    function replenishStabilityFund(uint256 amount) external nonReentrant {
        usdt.transferFrom(msg.sender, address(this), amount);
        
        if (stabilityFund.deployedFunds >= amount) {
            stabilityFund.deployedFunds -= amount;
        } else {
            stabilityFund.totalFunds += amount - stabilityFund.deployedFunds;
            stabilityFund.deployedFunds = 0;
        }
        
        emit StabilityFundReplenished(amount, stabilityFund.totalFunds);
    }
    
    /// @notice Activate emergency fund for crisis situations
    /// @param amount Amount to activate
    /// @param reason Reason for activation
    function activateEmergencyFund(uint256 amount, string calldata reason) external onlyEmergency {
        require(stabilityFund.reserveFunds >= amount, "INSUFFICIENT_RESERVE_FUNDS");
        
        stabilityFund.reserveFunds -= amount;
        stabilityFund.deployedFunds += amount;
        
        emit EmergencyFundActivated(amount, reason);
    }
    
    /// @notice Set maximum deployable amount for stability operations
    /// @param newMaxDeployment New maximum deployment amount
    function setMaxDeployment(uint256 newMaxDeployment) external onlyGovernance {
        stabilityFund.maxDeployment = newMaxDeployment;
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY CONTROLS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Emergency pause all treasury operations
    function emergencyPause() external onlyEmergency {
        emergencyPaused = true;
        emit EmergencyPaused(block.timestamp);
    }
    
    /// @notice Resume treasury operations after emergency
    function emergencyUnpause() external onlyOwner {
        emergencyPaused = false;
        emit EmergencyUnpaused(block.timestamp);
    }
    
    /// @notice Emergency withdrawal with multi-sig approval
    /// @param amount Amount to withdraw
    /// @param to Recipient address
    /// @param reason Emergency reason
    function emergencyWithdraw(uint256 amount, address to, string calldata reason) external {
        bytes32 operationHash = keccak256(abi.encodePacked("emergencyWithdraw", amount, to, reason, block.timestamp));
        
        if (!_hasRequiredApprovals(operationHash)) {
            _recordApproval(operationHash);
            return;
        }
        
        require(amount <= usdt.balanceOf(address(this)), "INSUFFICIENT_BALANCE");
        
        usdt.transfer(to, amount);
        
        emit EmergencyWithdrawal(to, amount, reason);
        emit OperationExecuted(operationHash, "emergencyWithdraw");
        _clearApprovals(operationHash);
    }
    
    /// @notice Freeze specific operations
    /// @param freezeDeposits Whether to freeze deposits
    /// @param freezeWithdrawals Whether to freeze withdrawals
    function freezeOperations(bool freezeDeposits, bool freezeWithdrawals) external onlyEmergency {
        depositsEnabled = !freezeDeposits;
        withdrawalsEnabled = !freezeWithdrawals;
    }

    /*//////////////////////////////////////////////////////////////
                        TIME-LOCKED WITHDRAWALS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Request a time-locked withdrawal
    /// @param amount Amount to withdraw
    /// @param reason Reason for withdrawal
    /// @return requestId Unique request identifier
    function requestWithdrawal(uint256 amount, string calldata reason) external onlyAuthorized returns (bytes32) {
        bytes32 requestId = keccak256(abi.encodePacked(msg.sender, amount, reason, block.timestamp));
        
        withdrawalRequests[requestId] = WithdrawalRequest({
            requester: msg.sender,
            amount: amount,
            requestTime: block.timestamp,
            executed: false,
            reason: reason
        });
        
        emit WithdrawalRequested(requestId, msg.sender, amount);
        return requestId;
    }
    
    /// @notice Execute a time-locked withdrawal after delay period
    /// @param requestId Request identifier
    function executeWithdrawal(bytes32 requestId) external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        require(!request.executed, "ALREADY_EXECUTED");
        require(block.timestamp >= request.requestTime + withdrawalDelay, "WITHDRAWAL_NOT_READY");
        require(request.amount <= collateralData.availableCollateral, "INSUFFICIENT_COLLATERAL");
        
        request.executed = true;
        collateralData.totalReserves -= request.amount;
        collateralData.availableCollateral -= request.amount;
        
        usdt.transfer(request.requester, request.amount);
        
        emit WithdrawalExecuted(requestId, request.amount);
    }

    /*//////////////////////////////////////////////////////////////
                        MULTI-SIGNATURE OPERATIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Add treasury operator
    /// @param operator Address to add as operator
    function addTreasuryOperator(address operator) external onlyOwner {
        treasuryOperators[operator] = true;
    }
    
    /// @notice Remove treasury operator
    /// @param operator Address to remove as operator
    function removeTreasuryOperator(address operator) external onlyOwner {
        treasuryOperators[operator] = false;
    }
    
    /// @notice Set required approvals for operations
    /// @param newRequirement New approval requirement
    function setRequiredApprovals(uint256 newRequirement) external onlyOwner {
        require(newRequirement > 0, "INVALID_REQUIREMENT");
        requiredApprovals = newRequirement;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMINISTRATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Set ecosystem contract addresses
    /// @param _usdpToken USDP token address
    /// @param _usdpStabilizer Stabilizer contract address
    /// @param _usdpManager Manager contract address
    /// @param _usdpOracle Oracle contract address
    function setEcosystemContracts(
        address _usdpToken,
        address _usdpStabilizer,
        address _usdpManager,
        address _usdpOracle
    ) external onlyOwner {
        usdpToken = _usdpToken;
        usdpStabilizer = _usdpStabilizer;
        usdpManager = _usdpManager;
        usdpOracle = _usdpOracle;
    }
    
    /// @notice Update governance address
    /// @param newGovernance New governance address
    function updateGovernance(address newGovernance) external onlyOwner {
        require(newGovernance != address(0), "INVALID_GOVERNANCE");
        address oldGovernance = governance;
        governance = newGovernance;
        emit GovernanceUpdated(oldGovernance, newGovernance);
    }
    
    /// @notice Transfer ownership
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        pendingOwner = newOwner;
    }
    
    /// @notice Accept ownership transfer
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING_OWNER");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }
    
    /// @notice Set withdrawal delay
    /// @param newDelay New delay in seconds
    function setWithdrawalDelay(uint256 newDelay) external onlyGovernance {
        require(newDelay <= MAX_WITHDRAWAL_DELAY, "DELAY_TOO_LONG");
        withdrawalDelay = newDelay;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Get treasury status
    /// @return totalReserves Total USDT reserves
    /// @return allocatedCollateral Allocated collateral amount
    /// @return availableCollateral Available collateral amount
    /// @return collateralRatio Current collateral ratio
    /// @return stabilityFundBalance Stability fund balance
    /// @return isEmergencyPaused Emergency pause status
    function getTreasuryStatus() external view returns (
        uint256 totalReserves,
        uint256 allocatedCollateral,
        uint256 availableCollateral,
        uint256 collateralRatio,
        uint256 stabilityFundBalance,
        bool isEmergencyPaused
    ) {
        totalReserves = collateralData.totalReserves;
        allocatedCollateral = collateralData.allocatedCollateral;
        availableCollateral = collateralData.availableCollateral;
        
        if (usdpToken != address(0)) {
            uint256 totalSupply = IERC20(usdpToken).totalSupply();
            collateralRatio = totalSupply == 0 ? type(uint256).max : (totalReserves * 1e18) / totalSupply;
        } else {
            collateralRatio = type(uint256).max;
        }
        
        stabilityFundBalance = stabilityFund.totalFunds;
        isEmergencyPaused = emergencyPaused;
    }
    
    /// @notice Get fee information
    /// @return Current fee structure
    function getFeeInformation() external view returns (FeeStructure memory) {
        return feeStructure;
    }
    
    /// @notice Get stability fund status
    /// @return Stability fund information
    function getStabilityFundStatus() external view returns (StabilityFund memory) {
        return stabilityFund;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Verify collateral ratio is maintained
    /// @param totalCollateral Total collateral amount
    /// @return True if ratio is sufficient
    function _verifyCollateralRatio(uint256 totalCollateral) internal view returns (bool) {
        if (usdpToken == address(0)) return true;
        
        uint256 totalSupply = IERC20(usdpToken).totalSupply();
        if (totalSupply == 0) return true;
        
        uint256 ratio = (totalCollateral * 1e18) / totalSupply;
        return ratio >= MIN_COLLATERAL_RATIO;
    }
    
    /// @notice Validate fee structure
    /// @param fees Fee structure to validate
    /// @return True if valid
    function _validateFeeStructure(FeeStructure calldata fees) internal pure returns (bool) {
        return fees.stabilityShare + fees.governanceShare + fees.developmentShare == BASIS_POINTS;
    }
    
    /// @notice Record approval for multi-sig operation
    /// @param operationHash Hash of the operation
    function _recordApproval(bytes32 operationHash) internal {
        require(treasuryOperators[msg.sender] || msg.sender == owner, "NOT_OPERATOR");
        require(!hasApproved[operationHash][msg.sender], "ALREADY_APPROVED");
        
        hasApproved[operationHash][msg.sender] = true;
        operatorApprovals[operationHash]++;
        
        emit OperationApproved(operationHash, msg.sender, operatorApprovals[operationHash]);
    }
    
    /// @notice Check if operation has required approvals
    /// @param operationHash Hash of the operation
    /// @return True if sufficient approvals
    function _hasRequiredApprovals(bytes32 operationHash) internal view returns (bool) {
        return operatorApprovals[operationHash] >= requiredApprovals;
    }
    
    /// @notice Clear approvals after operation execution
    /// @param operationHash Hash of the operation
    function _clearApprovals(bytes32 operationHash) internal {
        delete operatorApprovals[operationHash];
    }
}