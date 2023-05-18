// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Utilities.sol";
import "hardhat/console.sol";

interface IPARA {
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}

contract StakePool is AccessControl, Utilities {
    using SafeERC20 for IERC20;

    // para token
    address immutable para;
    IPARA PARA;

    // rewards pool - 33% of the staked PARA will be sent to this pool
    address immutable rewardsPoolAddress;

    constructor(
        address _para,
        uint256 _rewardsPerSecond,
        address _rewardsPoolAddress,
        uint256 _burnFee,
        uint256 _rewardFee,
        bool _burnFeeEnabled,
        bool _rewardFeeEnabled
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // _grantRole(MINTER_ROLE, msg.sender);

        // the governance token
        para = _para;
        PARA = IPARA(_para);
        rewardsPoolAddress = _rewardsPoolAddress;

        // set fees
        require(_burnFee + _rewardFee <= 100, "PARA: fees too high");
        
        burnFee = _burnFee;
        rewardFee = _rewardFee;
        burnFeeEnabled = _burnFeeEnabled;
        rewardFeeEnabled = _rewardFeeEnabled;

        addPool(_rewardsPerSecond);
    }

    function stake(uint256 newStakedParas, uint256 newStakedDays) external {
        /* Make sure staked amount is non-zero */
        require(newStakedParas != 0, "PARA: amount must be non-zero");

        /* enforce the minimum stake time */
        require(
            newStakedDays >= MIN_STAKE_DAYS,
            "PARA: newStakedDays lower than minimum"
        );

        /* enforce the maximum stake time */
        require(
            newStakedDays <= MAX_STAKE_DAYS,
            "PARA: newStakedDays higher than maximum"
        );

        Pool memory vPool = updatePool();

        uint256 newStakeShares = _stakeStartBonusParas(
            newStakedParas,
            newStakedDays
        );

        // get user position
        UserPosition storage userPosition = userPositions[msg.sender];
        userPosition.lastStakeId += 1;
        userPosition.stakeSharesTotal += newStakeShares;
        userPosition.totalAmount += newStakedParas;
        userPosition.rewardDebt =
            (userPosition.totalAmount * vPool.accParaPerShare) /
            PARA_PRECISION;

        /*
            The startStake timestamp will always be part-way through the current
            day, so it needs to be rounded-up to the next day to ensure all
            stakes align with the same fixed calendar days. The current day is
            already rounded-down, so rounded-up is current day + 1.
        */
        uint256 newPooledDay = block.timestamp / 1 days;

        /* Create Stake */
        uint256 newStakeId = userPosition.lastStakeId;
        _addStake(
            userPosition.stakes,
            newStakeId,
            newStakedParas,
            newStakeShares,
            newPooledDay,
            newStakedDays
        );

        emit StartStake(
            uint256(block.timestamp),
            msg.sender,
            newStakeId,
            newStakedParas,
            uint256(newStakedDays)
        );

        // update pool share
        virtualPool.totalPooled += newStakedParas;

        /* Transfer staked Paras to contract */
        IERC20(para).safeTransferFrom(
            msg.sender,
            address(this),
            newStakedParas
        );

        // burn 33% of the amount
        if (burnFeeEnabled) {
            PARA.burn((newStakedParas * burnFee) / 100);
        }

        // send the other 33% to the rewards pool
        if (rewardFeeEnabled) {
            IERC20(para).safeTransfer(
                rewardsPoolAddress,
                (newStakedParas * rewardFee) / 100
            );
        }
    }

    /**
     * @dev PUBLIC FACING: Closes a stake. The order of the stake list can change so
     * a stake id is used to reject stale indexes.
     * @param stakeIndex Index of stake within stake list
     */
    function endStake(uint256 stakeIndex) external {
        UserPosition storage userPosition = userPositions[msg.sender];
        Stake[] storage stakeListRef = userPosition.stakes;

        /* require() is more informative than the default assert() */
        require(stakeListRef.length != 0, "PARA: Empty stake list");
        require(stakeIndex < stakeListRef.length, "PARA: stakeIndex invalid");

        Stake storage stk = stakeListRef[stakeIndex];

        uint256 servedDays = 0;
        uint256 currentDay = block.timestamp / 1 days;
        servedDays = currentDay - stk.pooledDay;
        if (servedDays >= stk.stakedDays) {
            servedDays = stk.stakedDays;
        } else {
            revert("PARA: Locked stake");
        }

        // update pool status
        updatePool();
        virtualPool.totalPooled -= stk.stakedParas;

        // update rewardDebt
        userPosition.rewardDebt =
            (userPosition.totalAmount * virtualPool.accParaPerShare) /
            PARA_PRECISION;

        uint256 stakeReturn;
        uint256 payout = 0;

        (stakeReturn, payout) = calcStakeReturn(userPosition, stk, servedDays);

        _unpoolStake(userPosition, stk);

        emit EndStake(
            uint256(block.timestamp),
            msg.sender,
            stakeIndex,
            payout,
            uint256(servedDays)
        );

        if (stakeReturn != 0) {
            /* Transfer stake return from contract back to staker */
            IERC20(para).safeTransfer(msg.sender, stakeReturn);
        }

        // reset stake
        delete stakeListRef[stakeIndex];
    }

    /**
     * @dev Calculate stakeShares for a new stake, including any bonus
     * @param newStakedParas Number of Paras to stake
     * @param newStakedDays Number of days to stake
     */

    function _stakeStartBonusParas(
        uint256 newStakedParas,
        uint256 newStakedDays
    ) private pure returns (uint256 bonusParas) {
        /* Must be more than 1 day for Longer-Pays-Better */
        uint256 cappedExtraDays = newStakedDays - MIN_STAKE_DAYS;

        uint256 cappedStakedParas = newStakedParas <= LPB_A_CAP_PARA
            ? newStakedParas
            : LPB_A_CAP_PARA;

        bonusParas =
            (newStakedParas * cappedExtraDays) /
            LPB_D +
            (newStakedParas * cappedStakedParas) /
            LPB_A_CAP_PARA;
    }

    function calcStakeReturn(
        UserPosition memory usr,
        Stake memory st,
        uint256 servedDays
    ) internal view returns (uint256 stakeReturn, uint256 payout) {
        payout = calcPayoutRewards(
            st.stakeShares,
            st.pooledDay,
            st.pooledDay + servedDays,
            st.stakedDays
        );
        stakeReturn = st.stakedParas + payout;

        // get rewards based on the pool shares
        uint256 accParaPerShare = virtualPool.accParaPerShare;
        uint256 tokenSupply = IERC20(para).balanceOf(address(this));

        if (block.timestamp > virtualPool.lastRewardTime && tokenSupply != 0) {
            uint256 passedTime = block.timestamp - virtualPool.lastRewardTime;
            uint256 paraReward = passedTime * virtualPool.rewardsPerSecond;
            accParaPerShare =
                accParaPerShare +
                (paraReward * PARA_PRECISION) /
                tokenSupply;
        }
        uint256 pendingPoolShare = (
            ((usr.totalAmount * accParaPerShare) / PARA_PRECISION)
        ) - usr.rewardDebt;

        stakeReturn += pendingPoolShare;
        payout += pendingPoolShare;

        return (stakeReturn, payout);
    }

    /**
     * @dev PUBLIC FACING: Calculates total stake payout including rewards for a multi-day range
     * @param stakeShares param from stake to calculate bonus
     * @param beginDay first day to calculate bonuses for
     * @param endDay last day (non-inclusive) of range to calculate bonuses for
     * @param stakedDays staked days (non-inclusive) of range to calculate bonuses for
     * @return payout Paras
     */
    function calcPayoutRewards(
        uint256 stakeShares,
        uint256 beginDay,
        uint256 endDay,
        uint stakedDays
    ) public pure returns (uint256 payout) {
        payout += ((endDay - beginDay) / stakedDays) * stakeShares; // payout based on amount
        return payout;
    }

    // this function will be executed only once when the contract is deployed. no need of RBAC
    function addPool(uint256 _rewardsPerSecond) internal {
        require(
            _rewardsPerSecond > 0,
            "AddPool Failed: invalid reward per second."
        );
        virtualPool = Pool({
            totalPooled: 0,
            rewardsPerSecond: _rewardsPerSecond,
            accParaPerShare: 0,
            lastRewardTime: block.timestamp
        });
    }

    function updatePool() internal returns (Pool memory _vPool) {
        uint256 tokenSupply = IERC20(para).balanceOf(address(this));
        if (block.timestamp > virtualPool.lastRewardTime) {
            if (tokenSupply > 0) {
                uint256 passedTime = block.timestamp -
                    virtualPool.lastRewardTime;
                uint256 paraReward = passedTime * virtualPool.rewardsPerSecond;
                virtualPool.accParaPerShare +=
                    (paraReward * PARA_PRECISION) /
                    tokenSupply;
            }
            virtualPool.lastRewardTime = block.timestamp;

            return virtualPool;
        }
    }

    function _unpoolStake(UserPosition storage usr, Stake storage st) internal {
        usr.totalAmount -= st.stakedParas;
        usr.stakeSharesTotal -= st.stakeShares;
    }

    /**
    Getters
     */
    function getUserPosition(
        address _usr
    ) public view returns (UserPosition memory) {
        return userPositions[_usr];
    }

    function getStakeRewards(
        address _usr,
        uint256 _stkIdx
    ) public view returns (uint256 stakeReturn, uint256 payout) {
        // get user
        UserPosition memory usr = getUserPosition(_usr);
        // get stake
        Stake memory stk = usr.stakes[_stkIdx];

        uint256 currentDay = block.timestamp / 1 days;
        uint256 servedDays = 0;

        servedDays = currentDay - stk.pooledDay;
        if (servedDays >= stk.stakedDays) {
            servedDays = stk.stakedDays;
        } else {
            return (0, 0);
        }

        (stakeReturn, payout) = calcStakeReturn(usr, stk, servedDays);
    }

    /** Fee functions */
    function setBurnFee(uint256 _fee) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        require(_fee <= 100, "Fee must be less than 100");
        burnFee = _fee;
    }

    function setRewardFee(uint256 _fee) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        require(_fee <= 100, "Fee must be less than 100");
        rewardFee = _fee;
    }

    function setBurnEnabled(bool _enabled) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        burnFeeEnabled = _enabled;
    }

    function setRewardEnabled(bool _enabled) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        rewardFeeEnabled = _enabled;
    }
}