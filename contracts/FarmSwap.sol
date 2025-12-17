// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract FarmSwap is ReentrancyGuard, Ownable, Pausable {
    IERC20 public immutable TOKEN_A;
    IERC20 public immutable TOKEN_B;
    IERC20 public immutable REWARD_TOKEN;
   
    struct Pool {
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalSupply;
        uint256 lastUpdateTime;
        uint256 rewardPerLPTokenStored;
    }
   
    Pool public pool;
    uint256 public totalRewards;
    uint256 public rewardRate = 1e16;
    uint256 public constant FEE_BPS = 30;
    uint256 public constant PROTOCOL_FEE_BPS = 5;
    
    uint256 public constant MAX_REWARD_RATE = 1e20;
   
    mapping(address => uint256) public lpBalances;
    mapping(address => uint256) public userRewardPerLPTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public rewardDistributors;
    mapping(address => uint256) public userLockEndTime;
   
    uint256 public protocolFeesA;
    uint256 public protocolFeesB;
    uint256 public constant LOCK_PERIOD = 1 days;
   
    event LiquidityAdded(address indexed user, uint256 amountA, uint256 amountB, uint256 liquidity);
    event LiquidityRemoved(address indexed user, uint256 amountA, uint256 amountB, uint256 liquidity);
    event Swapped(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount);
    event RewardRateChanged(uint256 oldRate, uint256 newRate);
    event EmergencyWithdrawExecuted(address token, uint256 amount);
    event ProtocolFeesWithdrawn(uint256 amountA, uint256 amountB);
    event RewardDistributorUpdated(address indexed distributor, bool status);
   
    // ============ MODIFIERS ============

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }
   
    modifier onlyDistributor() {
        _onlyDistributor();
        _;
    }

    modifier validRate(uint256 rate) {
        require(rate <= MAX_REWARD_RATE, "Reward rate exceeds maximum");
        _;
    }
   
    // ============ CONSTRUCTOR ============
    
    constructor(address _tokenA, address _tokenB, address _rewardToken) Ownable() {
        require(_tokenA != address(0) && _tokenB != address(0) && _rewardToken != address(0), "Zero address");
        TOKEN_A = IERC20(_tokenA);
        TOKEN_B = IERC20(_tokenB);
        REWARD_TOKEN = IERC20(_rewardToken);
        pool.lastUpdateTime = block.timestamp;
        rewardDistributors[msg.sender] = true;
        _pause();
    }
   
    // ============ EXTERNAL FUNCTIONS ============
   
    /// @notice Adds liquidity to the pool and mints LP tokens.
    function addLiquidity(uint256 amountA, uint256 amountB)
        external
        nonReentrant
        updateReward(msg.sender)
        whenNotPaused
    {
        require(amountA > 0 && amountB > 0, "Invalid amounts");
       
        uint256 liquidity;
        if (pool.totalSupply == 0) {
            liquidity = _sqrt(amountA * amountB);
        } else {
            uint256 expectedAmountB = (amountA * pool.reserveB) / pool.reserveA;
            require(amountB >= expectedAmountB * 99 / 100, "Price slippage too high");
           
            uint256 liquidityA = (amountA * pool.totalSupply) / pool.reserveA;
            uint256 liquidityB = (amountB * pool.totalSupply) / pool.reserveB;
            liquidity = (liquidityA < liquidityB) ? liquidityA : liquidityB;
            require(liquidity > 0, "Insufficient liquidity");
        }
       
        _safeTransferFrom(TOKEN_A, msg.sender, address(this), amountA);
        _safeTransferFrom(TOKEN_B, msg.sender, address(this), amountB);
       
        pool.reserveA += amountA;
        pool.reserveB += amountB;
        pool.totalSupply += liquidity;
        lpBalances[msg.sender] += liquidity;
       
        emit LiquidityAdded(msg.sender, amountA, amountB, liquidity);
    }
   
    /// @notice Removes liquidity from the pool and burns LP tokens.
    function removeLiquidity(uint256 liquidity)
        external
        nonReentrant
        updateReward(msg.sender)
        whenNotPaused
    {
        require(liquidity > 0 && lpBalances[msg.sender] >= liquidity, "Invalid liquidity");
       
        uint256 amountA = (liquidity * pool.reserveA) / pool.totalSupply;
        uint256 amountB = (liquidity * pool.reserveB) / pool.totalSupply;
       
        require(amountA > 0 && amountB > 0, "Insufficient liquidity");
       
        pool.reserveA -= amountA;
        pool.reserveB -= amountB;
        pool.totalSupply -= liquidity;
        lpBalances[msg.sender] -= liquidity;
       
        _safeTransfer(TOKEN_A, msg.sender, amountA);
        _safeTransfer(TOKEN_B, msg.sender, amountB);
       
        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidity);
    }
   
    /// @notice Swaps one token for another using the AMM formula.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        updateReward(msg.sender)
        whenNotPaused
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Invalid amount");
        require(tokenIn == address(TOKEN_A) || tokenIn == address(TOKEN_B), "Invalid token");
       
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(tokenIn);
       
        uint256 amountInWithFee = amountIn * (10000 - FEE_BPS) / 10000;
        uint256 protocolFee = amountIn * PROTOCOL_FEE_BPS / 10000;
        
        if (protocolFee > amountInWithFee) {
            protocolFee = amountInWithFee;
            amountInWithFee = 0;
        } else {
            amountInWithFee -= protocolFee;
        }
        
        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
       
        require(amountOut >= minAmountOut, "Slippage too high");
        require(amountOut > 0 && amountOut <= reserveOut, "Insufficient liquidity");
       
        if (tokenIn == address(TOKEN_A)) {
            pool.reserveA += amountIn;
            pool.reserveB -= amountOut;
            protocolFeesA += protocolFee;
            _safeTransferFrom(TOKEN_A, msg.sender, address(this), amountIn);
            _safeTransfer(TOKEN_B, msg.sender, amountOut);
        } else {
            pool.reserveB += amountIn;
            pool.reserveA -= amountOut;
            protocolFeesB += protocolFee;
            _safeTransferFrom(TOKEN_B, msg.sender, address(this), amountIn);
            _safeTransfer(TOKEN_A, msg.sender, amountOut);
        }
       
        emit Swapped(msg.sender, tokenIn, amountIn, amountOut);
    }
   
    /// @notice Claims accumulated rewards for the caller.
    function claimRewards() external nonReentrant updateReward(msg.sender) whenNotPaused {
        require(block.timestamp >= userLockEndTime[msg.sender], "Rewards locked");
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards to claim");
       
        rewards[msg.sender] = 0;
        _safeTransfer(REWARD_TOKEN, msg.sender, reward);
       
        userLockEndTime[msg.sender] = block.timestamp + LOCK_PERIOD;
       
        emit RewardsClaimed(msg.sender, reward);
    }
   
    // ============ REWARD MANAGEMENT ============
   
    /// @notice Funds the reward pool with additional tokens.
    function fundRewards(uint256 amount) external onlyDistributor {
        require(amount > 0, "Invalid amount");
       
        _safeTransferFrom(REWARD_TOKEN, msg.sender, address(this), amount);
        totalRewards += amount;
       
        emit RewardsFunded(msg.sender, amount);
    }
   
    /// @notice Sets a reward distributor status.
    function setRewardDistributor(address distributor, bool status) external onlyOwner {
        require(distributor != address(0), "Zero address");
        rewardDistributors[distributor] = status;
        emit RewardDistributorUpdated(distributor, status);
    }
   
    /// @notice Sets a new reward rate.
    function setRewardRate(uint256 newRate) external onlyOwner validRate(newRate) {
        _updateRewardInternal();
        uint256 oldRate = rewardRate;
        rewardRate = newRate;
        
        emit RewardRateChanged(oldRate, newRate);
    }
   
    // ============ VIEW FUNCTIONS ============
   
    /// @notice Returns the earned rewards for an account.
    function earned(address account) public view returns (uint256) {
        uint256 currentRewardPerLpToken = getRewardPerLpToken();
        uint256 userPaid = userRewardPerLPTokenPaid[account];
    
        uint256 pending = 0;
        if (currentRewardPerLpToken > userPaid) {
            pending = (lpBalances[account] * (currentRewardPerLpToken - userPaid)) / 1e18;
        }   
    
        return pending + rewards[account];
    }
   
    /// @notice Returns the current reward per LP token.
    function getRewardPerLpToken() public view returns (uint256) {
        if (pool.totalSupply == 0 || totalRewards == 0) {
            return pool.rewardPerLPTokenStored;
        }
   
        uint256 timePassed = block.timestamp - pool.lastUpdateTime;
        uint256 rewardToAdd = (timePassed * rewardRate * 1e18) / pool.totalSupply;
   
        uint256 availableReward = (totalRewards * 1e18) / pool.totalSupply;
        if (rewardToAdd > availableReward) {
            rewardToAdd = availableReward;
        }
   
        return pool.rewardPerLPTokenStored + rewardToAdd;
    }
   
    /// @notice Returns the current reserves of TOKEN_A and TOKEN_B.
    function getReserves() public view returns (uint256, uint256) {
        return (pool.reserveA, pool.reserveB);
    }

    /// @notice Returns maximum reward rate
    function getMaxRewardRate() external pure returns (uint256) {
        return MAX_REWARD_RATE;
    }
   
    // ============ INTERNAL FUNCTIONS ============
   
    function _updateReward(address account) internal {
        _updateRewardInternal();
        if (account != address(0)) {
            _updateUserReward(account);
        }
    }
   
    function _updateRewardInternal() internal {
        if (pool.totalSupply == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }
       
        uint256 timePassed = block.timestamp - pool.lastUpdateTime;
        uint256 rewardToDistribute = timePassed * rewardRate;
       
        if (rewardToDistribute > totalRewards) {
            rewardToDistribute = totalRewards;
        }
       
        if (rewardToDistribute > 0) {
            pool.rewardPerLPTokenStored += (rewardToDistribute * 1e18) / pool.totalSupply;
            totalRewards -= rewardToDistribute;
        }
       
        pool.lastUpdateTime = block.timestamp;
    }
   
    function _onlyDistributor() internal view {
        require(rewardDistributors[msg.sender], "Not a reward distributor");
    }
   
    function _updateUserReward(address account) internal {
        uint256 pending = (lpBalances[account] * (pool.rewardPerLPTokenStored - userRewardPerLPTokenPaid[account])) / 1e18;
        rewards[account] += pending;
        userRewardPerLPTokenPaid[account] = pool.rewardPerLPTokenStored;
    }
   
    function _getReserves(address tokenIn) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == address(TOKEN_A)) {
            return (pool.reserveA, pool.reserveB);
        } else {
            return (pool.reserveB, pool.reserveA);
        }
    }
   
    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(to != address(0), "Transfer to zero address");
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }
   
    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }
   
    function _sqrt(uint256 x) internal pure returns (uint256) {
        return Math.sqrt(x);
    }

    // ============ ADMIN FUNCTIONS ============

    /// @notice Pauses the contract, preventing user interactions.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing user interactions.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraws stuck tokens in emergency (excluding pool tokens).
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(TOKEN_A) && token != address(TOKEN_B) && token != address(REWARD_TOKEN),
                "Cannot withdraw pool or reward tokens via emergency");
        _safeTransfer(IERC20(token), owner(), amount);
        emit EmergencyWithdrawExecuted(token, amount);
    }

    /// @notice Withdraws accumulated protocol fees.
    function withdrawProtocolFees() external onlyOwner {
        uint256 amountA = protocolFeesA;
        uint256 amountB = protocolFeesB;
        
        require(amountA > 0 || amountB > 0, "No fees to withdraw");
        
        if (amountA > 0) {
            protocolFeesA = 0;
            _safeTransfer(TOKEN_A, owner(), amountA);
        }
        
        if (amountB > 0) {
            protocolFeesB = 0;
            _safeTransfer(TOKEN_B, owner(), amountB);
        }
        
        emit ProtocolFeesWithdrawn(amountA, amountB);
    }

    /// @notice Withdraws excess reward tokens (beyond allocated rewards).
    function withdrawExcessRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        
        uint256 rewardsNeeded = totalRewards;
        uint256 currentBalance = REWARD_TOKEN.balanceOf(address(this));
        
        require(currentBalance > rewardsNeeded + amount, "Insufficient excess rewards");
        
        _safeTransfer(REWARD_TOKEN, owner(), amount);
    }
}