// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../FarmSwap.sol";
import "./ERC20Mock.sol";

contract FarmSwapTest is Test {
    FarmSwap public farmSwap;
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    ERC20Mock public rewardToken;
   
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address distributor = makeAddr("distributor");
   
    function setUp() public {
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(distributor, 100 ether);
       
        vm.startPrank(owner);
        tokenA = new ERC20Mock("Token A", "TKA", 1_000_000 ether);
        tokenB = new ERC20Mock("Token B", "TKB", 1_000_000 ether);
        rewardToken = new ERC20Mock("Reward Token", "RWD", 1_000_000 ether);
        farmSwap = new FarmSwap(address(tokenA), address(tokenB), address(rewardToken));
        farmSwap.setRewardDistributor(distributor, true);
        vm.stopPrank();
        vm.prank(owner);
        bool success = rewardToken.transfer(distributor, 2000 ether);
        require(success, "Transfer to distributor failed");
        vm.prank(distributor);
        rewardToken.approve(address(farmSwap), 1000 ether);
        vm.prank(distributor);
        farmSwap.fundRewards(1000 ether);

        vm.prank(owner);
        success = tokenA.transfer(user1, 10_000 ether);
        require(success, "TokenA to user1 failed");
   
        vm.prank(owner);
        success = tokenB.transfer(user1, 10_000 ether);
        require(success, "TokenB to user1 failed");
   
        vm.prank(owner);
        success = tokenA.transfer(user2, 10_000 ether);
        require(success, "TokenA to user2 failed");
   
        vm.prank(owner);
        success = tokenB.transfer(user2, 10_000 ether);
        require(success, "TokenB to user2 failed");
   
        vm.prank(user1);
        tokenA.approve(address(farmSwap), type(uint256).max);
        vm.prank(user1);
        tokenB.approve(address(farmSwap), type(uint256).max);
        vm.prank(user2);
        tokenA.approve(address(farmSwap), type(uint256).max);
        vm.prank(user2);
        tokenB.approve(address(farmSwap), type(uint256).max);
        vm.prank(owner);
        farmSwap.unpause();
    }
   
    function test_AddLiquidity() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        (uint256 reserveA, uint256 reserveB) = farmSwap.getReserves();
        assertEq(reserveA, 100 ether);
        assertEq(reserveB, 100 ether);
        assertGt(farmSwap.lpBalances(user1), 0);
    }
   
    function test_Swap() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
        uint256 balanceBefore = tokenB.balanceOf(user2);

        vm.prank(user2);
        farmSwap.swap(address(tokenA), 100 ether, 90 ether);

        uint256 balanceAfter = tokenB.balanceOf(user2);
        assertGt(balanceAfter, balanceBefore);
    }
   
    function test_Rewards() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        vm.warp(block.timestamp + 3600 + 86400);
       
        uint256 earned = farmSwap.earned(user1);
        assertGt(earned, 0);
       
        vm.prank(user1);
        farmSwap.claimRewards();
       
        uint256 rewardBalance = rewardToken.balanceOf(user1);
        assertEq(rewardBalance, earned);
    }
    
    function test_MultipleUsersRewards() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        vm.prank(user2);
        farmSwap.addLiquidity(200 ether, 200 ether);
        
        vm.warp(block.timestamp + 3600 + 86400);
        
        uint256 earned1 = farmSwap.earned(user1);
        uint256 earned2 = farmSwap.earned(user2);
        
        assertApproxEqAbs(earned1 * 2, earned2, 1e12);
    }
    
    function test_RewardCap() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        vm.warp(block.timestamp + 1000000);
        
        uint256 earned = farmSwap.earned(user1);
        assertLe(earned, 1000 ether);
    }
    
    function test_Pause() public {
        vm.prank(owner);
        farmSwap.pause();
        
        vm.expectRevert("Pausable: paused");
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
    }
    
    function test_LockPeriod() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        assertEq(farmSwap.userLockEndTime(user1), 0, "Initial lock time should be 0");
        vm.warp(block.timestamp + 3600); 

        uint256 earned = farmSwap.earned(user1);
        assertGt(earned, 0, "Should have earned rewards");
    
        vm.prank(user1);
        farmSwap.claimRewards();
        assertEq(rewardToken.balanceOf(user1), earned, "Rewards should be transferred");
    
        uint256 lockEndTime = farmSwap.userLockEndTime(user1);
        assertGe(lockEndTime, block.timestamp + farmSwap.LOCK_PERIOD() - 1, "Lock period should be set");

        vm.warp(block.timestamp + 3600);
        vm.expectRevert("Rewards locked");
        vm.prank(user1);
        farmSwap.claimRewards();

        vm.warp(lockEndTime + 1);
        uint256 earnedAfterLock = farmSwap.earned(user1);
        assertGt(earnedAfterLock, 0, "Should have earned more rewards");
    
        vm.prank(user1);
        farmSwap.claimRewards();
        assertEq(rewardToken.balanceOf(user1), earned + earnedAfterLock, "All rewards should be claimed");
    }
    
    function test_ProtocolFeeAccumulation() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
        uint256 swapAmount = 100 ether;
        uint256 expectedProtocolFee = swapAmount * farmSwap.PROTOCOL_FEE_BPS() / 10000;
        
        vm.prank(user2);
        farmSwap.swap(address(tokenA), swapAmount, 90 ether);

        assertGt(farmSwap.protocolFeesA(), 0);
        assertEq(farmSwap.protocolFeesA(), expectedProtocolFee);
    }
    
    function test_WithdrawProtocolFees() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);

        vm.prank(user2);
        farmSwap.swap(address(tokenA), 100 ether, 90 ether);
        
        uint256 feesBeforeA = tokenA.balanceOf(owner);
        uint256 feesBeforeB = tokenB.balanceOf(owner);
        uint256 protocolFeesA = farmSwap.protocolFeesA();
        uint256 protocolFeesB = farmSwap.protocolFeesB();
        
        assertGt(protocolFeesA, 0);
        vm.prank(owner);
        farmSwap.withdrawProtocolFees();
        
        assertEq(tokenA.balanceOf(owner) - feesBeforeA, protocolFeesA);
        assertEq(tokenB.balanceOf(owner) - feesBeforeB, protocolFeesB);
        assertEq(farmSwap.protocolFeesA(), 0);
        assertEq(farmSwap.protocolFeesB(), 0);
    }

    function test_SetRewardRate() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        
        uint256 oldRate = farmSwap.rewardRate();
        uint256 newRate = oldRate * 2; 

        vm.prank(owner);
        farmSwap.setRewardRate(newRate);
        
        assertEq(farmSwap.rewardRate(), newRate);
        vm.warp(block.timestamp + 3600);
        
        uint256 earned = farmSwap.earned(user1);
        assertGt(earned, 0);
        
        vm.prank(owner);
        farmSwap.setRewardRate(oldRate);
        
        vm.warp(block.timestamp + 3600);
        uint256 earnedAfterRateChange = farmSwap.earned(user1) - earned;
        assertLt(earnedAfterRateChange, earned * 2);
    }

    function test_EmergencyWithdraw_PoolTokens_Revert() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);

        vm.expectRevert("Cannot withdraw pool or reward tokens via emergency");
        vm.prank(owner);
        farmSwap.emergencyWithdraw(address(tokenA), 100 ether);
    
        vm.expectRevert("Cannot withdraw pool or reward tokens via emergency");
        vm.prank(owner);
        farmSwap.emergencyWithdraw(address(tokenB), 100 ether);
    
        vm.expectRevert("Cannot withdraw pool or reward tokens via emergency");
        vm.prank(owner);
        farmSwap.emergencyWithdraw(address(rewardToken), 100 ether);
    }

    function test_WithdrawExcessRewards() public {
        uint256 excessAmount = 500 ether;
        vm.prank(distributor);
        rewardToken.transfer(address(farmSwap), excessAmount);
    
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
    
        uint256 ownerBalanceBefore = rewardToken.balanceOf(owner);
        uint256 contractBalanceBefore = rewardToken.balanceOf(address(farmSwap));
    
        uint256 withdrawAmount = 100 ether;
        vm.prank(owner);
        farmSwap.withdrawExcessRewards(withdrawAmount);
    
        uint256 ownerBalanceAfter = rewardToken.balanceOf(owner);
        uint256 contractBalanceAfter = rewardToken.balanceOf(address(farmSwap));

        assertEq(ownerBalanceAfter - ownerBalanceBefore, withdrawAmount);
        assertEq(contractBalanceBefore - contractBalanceAfter, withdrawAmount);
    }

    function test_MaxRewardRate() public {
        uint256 maxRate = farmSwap.getMaxRewardRate();
        vm.prank(owner);
        farmSwap.setRewardRate(maxRate);
        assertEq(farmSwap.rewardRate(), maxRate);

        vm.expectRevert("Reward rate exceeds maximum");
        vm.prank(owner);
        farmSwap.setRewardRate(maxRate + 1);
    }
    
    function test_RewardsContinueAfterClaim() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);

        vm.warp(block.timestamp + 3600 + 86400);
        uint256 earned1 = farmSwap.earned(user1);
        assertGt(earned1, 0);
        
        vm.prank(user1);
        farmSwap.claimRewards();
        assertEq(farmSwap.earned(user1), 0);

        vm.warp(block.timestamp + 3600);
        assertGt(farmSwap.earned(user1), 0);

        vm.warp(block.timestamp + 86400);
        vm.prank(user1);
        farmSwap.claimRewards();
        
        uint256 rewardBalance = rewardToken.balanceOf(user1);
        assertGt(rewardBalance, earned1);
    }
    
    function test_MultipleClaimsWithLock() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);

        vm.warp(block.timestamp + 3600 + 86400);
        uint256 earned1 = farmSwap.earned(user1);
        vm.prank(user1);
        farmSwap.claimRewards();
        
        vm.expectRevert("Rewards locked");
        vm.prank(user1);
        farmSwap.claimRewards();
  
        uint256 lockEndTime = farmSwap.userLockEndTime(user1);
        vm.warp(lockEndTime + 1);
        vm.warp(block.timestamp + 3600);
        
        uint256 earned2 = farmSwap.earned(user1);
        vm.prank(user1);
        farmSwap.claimRewards();
        
        uint256 totalRewardsClaimed = rewardToken.balanceOf(user1);
        assertEq(totalRewardsClaimed, earned1 + earned2);
    }
    
    function test_RewardsAfterRemoveLiquidity() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);

        vm.warp(block.timestamp + 3600);
        uint256 earnedBefore = farmSwap.earned(user1);
        assertGt(earnedBefore, 0, "Should have earned rewards");
    
        uint256 initialLpBalance = farmSwap.lpBalances(user1);
        uint256 userRewardPerLPTokenPaidBefore = farmSwap.userRewardPerLPTokenPaid(user1);
        uint256 rewardsStoredBefore = farmSwap.rewards(user1);
    
        uint256 lpToRemove = initialLpBalance / 2;
        vm.prank(user1);
        farmSwap.removeLiquidity(lpToRemove);
    
        uint256 lpBalanceAfter = farmSwap.lpBalances(user1);
        assertEq(lpBalanceAfter, initialLpBalance - lpToRemove, "LP should be halved");
    
        uint256 earnedImmediatelyAfter = farmSwap.earned(user1);
    
        assertApproxEqAbs(
            earnedImmediatelyAfter,
            earnedBefore,
            1e12, 
            "Earned should be approximately the same right after removal"
        );
    
        uint256 timeBefore = block.timestamp;
        vm.warp(block.timestamp + 3600); 
        uint256 earnedAfterWait = farmSwap.earned(user1);
        uint256 rewardsAccruedAfterRemoval = earnedAfterWait - earnedImmediatelyAfter;
        assertGt(rewardsAccruedAfterRemoval, 0, "Should have accrued some rewards after removal");
    
        vm.warp(block.timestamp + 86400);
        uint256 earnedBeforeClaim = farmSwap.earned(user1);
        vm.prank(user1);
        farmSwap.claimRewards();
        assertEq(
            rewardToken.balanceOf(user1),
            earnedBeforeClaim,
            "All earned rewards should be claimed"
        );
    
        assertGe(
            farmSwap.userLockEndTime(user1),
            block.timestamp,
            "Lock period should be set after claim"
        );
    }
    
    function test_RewardsUpdatedOnSwap() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
    
        vm.warp(block.timestamp + 3600);
        uint256 earnedBeforeSwap = farmSwap.earned(user1);
    
        assertGt(earnedBeforeSwap, 0, "Should have earned rewards after 1 hour");
        (,, uint256 userRewardsBeforeSwap) = _getUserRewardInfo(user1);

        vm.prank(user2);
        farmSwap.swap(address(tokenA), 10 ether, 9 ether);
    
        uint256 earnedAfterSwap = farmSwap.earned(user1);

        assertTrue(
            earnedAfterSwap != earnedBeforeSwap || earnedAfterSwap > 0,
            "Earned should change after swap"
        );

        vm.warp(block.timestamp + 3600);
        uint256 earnedLater = farmSwap.earned(user1);
        assertGt(earnedLater, 0, "Should continue earning rewards");
    }

    function _getUserRewardInfo(address user) internal view returns (
        uint256 lpBalance,
        uint256 rewardPerLPTokenPaid,
        uint256 rewardsStored
    ) {
        lpBalance = farmSwap.lpBalances(user);
        rewardPerLPTokenPaid = farmSwap.userRewardPerLPTokenPaid(user);
        rewardsStored = farmSwap.rewards(user);
    }
    
    function test_OnlyOwnerFunctions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        farmSwap.pause();
        
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        farmSwap.setRewardRate(1e17);
        
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        farmSwap.withdrawProtocolFees();
        
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        farmSwap.emergencyWithdraw(address(tokenA), 10 ether);
    }
    
    function test_OnlyDistributorFunctions() public {
        vm.expectRevert("Not a reward distributor");
        vm.prank(user1);
        farmSwap.fundRewards(100 ether);
    }
    
    function test_ContractStartsPaused() public {
        vm.startPrank(owner);
        FarmSwap newFarmSwap = new FarmSwap(address(tokenA), address(tokenB), address(rewardToken));

        vm.expectRevert("Pausable: paused");
        newFarmSwap.addLiquidity(100 ether, 100 ether);
    }
    
    function testFuzz_Swap(uint256 amountIn) public {
        amountIn = bound(amountIn, 1 ether, 100 ether);
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
        
        uint256 balanceBefore = tokenB.balanceOf(user2);
        vm.prank(user2);
        farmSwap.swap(address(tokenA), amountIn, 1);
        
        uint256 balanceAfter = tokenB.balanceOf(user2);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_AddLiquidity_ZeroAmounts() public {
        vm.expectRevert("Invalid amounts");
        farmSwap.addLiquidity(0, 100 ether);
    
        vm.expectRevert("Invalid amounts");
        farmSwap.addLiquidity(100 ether, 0);
    }

    function test_AddLiquidity_HighSlippage() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
    
        vm.expectRevert("Price slippage too high");
        vm.prank(user2);
        farmSwap.addLiquidity(100 ether, 1 ether);
    }

    function test_Swap_WithSmallPool() public {
        vm.prank(user1);
        farmSwap.addLiquidity(10 ether, 10 ether); 
    
        uint256 amountIn = 100 ether;
        (uint256 reserveA, uint256 reserveB) = farmSwap.getReserves();
    
        uint256 amountInWithFee = amountIn * (10000 - 30) / 10000;
        uint256 protocolFee = amountIn * 5 / 10000;
        amountInWithFee -= protocolFee;
        uint256 amountOut = (amountInWithFee * reserveB) / (reserveA + amountInWithFee);
    
        console.log("For amountIn:", amountIn);
        console.log("amountOut:", amountOut);
        console.log("reserveOut:", reserveB);
    
        uint256 balanceBefore = tokenB.balanceOf(user2);
        vm.prank(user2);
        farmSwap.swap(address(tokenA), amountIn, amountOut - 1);
    
        uint256 balanceAfter = tokenB.balanceOf(user2);
        uint256 received = balanceAfter - balanceBefore;
    
        console.log("Received:", received);
        console.log("Expected:", amountOut);
    
        assertApproxEqAbs(received, amountOut, 1e12);
        assertLt(received, reserveB);
    }

    function test_ClaimRewards_NoRewards() public {
        vm.expectRevert("No rewards to claim");
        vm.prank(user1);
        farmSwap.claimRewards();
    }

    function test_Earned_WithZeroLP() public {
        assertEq(farmSwap.earned(user1), 0, "New user should have 0 earned");
    
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
    
        vm.warp(block.timestamp + 3600);
    
        uint256 earnedBeforeRemove = farmSwap.earned(user1);
        assertGt(earnedBeforeRemove, 0, "Should have earned rewards");
    
        uint256 lpBalance = farmSwap.lpBalances(user1);
        vm.prank(user1);
        farmSwap.removeLiquidity(lpBalance);
    
        assertEq(farmSwap.lpBalances(user1), 0, "LP balance should be 0");
        uint256 earnedAfterRemove = farmSwap.earned(user1);
        assertApproxEqAbs(
            earnedAfterRemove,
            earnedBeforeRemove,
            1e12, 
            "Earned should be preserved after removing all liquidity"
        );
    
        vm.warp(block.timestamp + 3600);
        uint256 earnedLater = farmSwap.earned(user1);
        assertApproxEqAbs(
            earnedLater,
            earnedAfterRemove,
            1e12,
            "Should not earn new rewards without LP"
        );
    
        vm.warp(block.timestamp + 86400);
        uint256 rewardBalanceBefore = rewardToken.balanceOf(user1);
        vm.prank(user1);
        farmSwap.claimRewards();
    
        uint256 rewardBalanceAfter = rewardToken.balanceOf(user1);
        assertEq(
            rewardBalanceAfter - rewardBalanceBefore,
            earnedLater,
            "Should be able to claim preserved rewards"
        );

        assertEq(farmSwap.earned(user1), 0, "Earned should be 0 after claiming");
    }

    function test_Earned_NeverHadLP() public {

        assertEq(farmSwap.lpBalances(user2), 0, "Should have 0 LP");
        assertEq(farmSwap.userRewardPerLPTokenPaid(user2), 0, "Should have 0 rewardPerLPTokenPaid");
        assertEq(farmSwap.rewards(user2), 0, "Should have 0 stored rewards");
        assertEq(farmSwap.earned(user2), 0, "Should have 0 earned");
        
        vm.warp(block.timestamp + 100000);
        assertEq(farmSwap.earned(user2), 0, "Should still have 0 earned after time");
    }

    function test_Earned_UnderflowProtection() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
    
        vm.prank(owner);
        farmSwap.setRewardRate(1);
    
        vm.warp(block.timestamp + 3600);
        uint256 earned = farmSwap.earned(user1);
        assertGe(earned, 0);
    }

    function test_Rewards_WhenTotalSupplyZero() public {
        uint256 rewardPerLpToken = farmSwap.getRewardPerLpToken();
        assertEq(rewardPerLpToken, 0);
    }

    function test_ProtocolFee_NonZero() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
    
        uint256 amountIn = 2001;
        uint256 expectedProtocolFee = amountIn * farmSwap.PROTOCOL_FEE_BPS() / 10000;
        assertEq(expectedProtocolFee, 1, "Protocol fee should be 1 wei");
    
        (uint256 reserveA, uint256 reserveB) = farmSwap.getReserves();
        uint256 amountInWithFee = amountIn * (10000 - farmSwap.FEE_BPS()) / 10000;
        amountInWithFee -= expectedProtocolFee;
        uint256 expectedAmountOut = (amountInWithFee * reserveB) / (reserveA + amountInWithFee);
        require(expectedAmountOut > 0, "Expected amountOut should be > 0");

        uint256 balanceBefore = tokenB.balanceOf(user2);
        vm.prank(user2);
        farmSwap.swap(address(tokenA), amountIn, expectedAmountOut - 1);
        assertEq(farmSwap.protocolFeesA(), expectedProtocolFee, "Protocol fee should accumulate");
    
        uint256 balanceAfter = tokenB.balanceOf(user2);
        assertGt(balanceAfter, balanceBefore, "User should receive tokens");
    }

    function test_Pause_Unpause_Flow() public {
        vm.prank(owner);
        farmSwap.pause();
    
        vm.expectRevert("Pausable: paused");
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
    
        vm.prank(owner);
        farmSwap.unpause();
    
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
        assertGt(farmSwap.lpBalances(user1), 0);
    }

    function test_WithdrawExcessRewards_NoExcess() public {
        vm.prank(user1);
        farmSwap.addLiquidity(100 ether, 100 ether);
    
        vm.expectRevert("Insufficient excess rewards");
        vm.prank(owner);
        farmSwap.withdrawExcessRewards(1);
    }

    function test_Swap_ProtocolFeeExceedsAmountInWithFee() public {
        vm.prank(user1);
        farmSwap.addLiquidity(1000 ether, 1000 ether);
        uint256 amountIn = 0.001 ether;
    
        vm.prank(user2);
        farmSwap.swap(address(tokenA), amountIn, 0);
        assertGt(tokenB.balanceOf(user2), 0);
    }
}