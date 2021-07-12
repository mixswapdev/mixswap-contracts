// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IMixSwapReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./MixSwapToken.sol";


// MasterChef is the master of the tokens. He can make them and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once the token is sufficiently
// distributed and the community can show to govern itself.
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Tokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMxsPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMXSPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Tokens to distribute per block.
        uint256 lastRewardBlock;  // Last block number that tokens distribution occurs.
        uint256 accMxsPerShare;   // Accumulated Token per share, times 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The TOKEN!
    MixSwapToken public MXS;
    address public devAddress;
    address public feeAddress;
    address public marketingAddress;
    uint public marketingFeeBP;

    // Max marketing fee rate: 15%.
    uint16 public constant MAXIMUM_MARKETING_FEE_RATE = 1500;
    // Tokens created per block. 0.1mxs/block
    uint256 public mxsPerBlock = 100000000000000000;


    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Token mining starts.
    uint256 public startBlock;

    // Token referral contract address.
    IMixSwapReferral public referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 1500;
    // Max referral commission rate: 15%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1500;




    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event SetMarketingAddress(address indexed user, address indexed newAddress);
    event SetMarketingFee(address indexed user, uint16 marketingFeeBP);
    event UpdateEmissionRate(address indexed user, uint256 mxsPerBlock);
    event SetReferralAddress(address indexed user, IMixSwapReferral indexed newAddress);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        MixSwapToken _MXS,
        uint256 _startBlock,
        address _devAddress,
        address _feeAddress,
        address _marketingAddress,
        uint16 _marketingFeeBP
    ) public {
        MXS = _MXS;
        startBlock = _startBlock;

        devAddress = _devAddress;
        feeAddress = _feeAddress;
        marketingAddress = _marketingAddress;
        marketingFeeBP = _marketingFeeBP;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IBEP20 => bool) public poolExistence;


    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP) public onlyOwner {
        require(_depositFeeBP <= 1000, "add: invalid deposit fee basis points, max 10%");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accMxsPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's Tokens allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) public onlyOwner {
        require(_depositFeeBP <= 1000, "set: invalid deposit fee basis points, max 10%");
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending Tokens on frontend.
    function pendingMxs(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMxsPerShare = pool.accMxsPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 mxsReward = multiplier.mul(mxsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accMxsPerShare = accMxsPerShare.add(mxsReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMxsPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 mxsReward = multiplier.mul(mxsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        MXS.mint(devAddress, mxsReward.div(10));
        MXS.mint(marketingAddress, mxsReward.mul(marketingFeeBP).div(10000));
        MXS.mint(address(this), mxsReward);
        pool.accMxsPerShare = pool.accMxsPerShare.add(mxsReward.mul(1e18).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for Token allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            referral.recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMxsPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                if (referral.getReferrer(msg.sender)!=address(0) && address(referral) != address(0)) {
                    safeMxsTransfer(msg.sender, pending.sub(pending.mul(referralCommissionRate).div(10000))); //Takes the comission from the user
                    payReferralCommission(msg.sender, pending);
                }
                else {
                    safeMxsTransfer(msg.sender, pending);
                }
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accMxsPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public  {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMxsPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            if (referral.getReferrer(msg.sender)!=address(0) && address(referral) != address(0)) {
                    safeMxsTransfer(msg.sender, pending.sub(pending.mul(referralCommissionRate).div(10000))); //Takes the comission from the user
                    payReferralCommission(msg.sender, pending);
            }
            else {
                    safeMxsTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMxsPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }


    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public  {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe Token transfer function, just in case if rounding error causes pool to not have enough FOXs.
    function safeMxsTransfer(address _to, uint256 _amount) internal {
        uint256 mxsBal = MXS.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > mxsBal) {
            transferSuccess = MXS.transfer(_to, mxsBal);
        } else {
            transferSuccess = MXS.transfer(_to, _amount);
        }
        require(transferSuccess, "safeTransfer: Transfer failed");
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) external onlyOwner {
        devAddress = _devAddress;
        emit SetDevAddress(msg.sender, _devAddress);
    }

    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function setMarketingAddress(address _marketingAddress) external onlyOwner {
        marketingAddress = _marketingAddress;
        emit SetMarketingAddress(msg.sender, _marketingAddress);
    }

    // Update marketing fee by the owner
    function setMarketingFee(uint16 _marketingFeeBP) external onlyOwner {
        require(_marketingFeeBP <= MAXIMUM_MARKETING_FEE_RATE, "setMarketingFee: invalid marketing fee basis points, max 15%");
        marketingFeeBP = _marketingFeeBP;
        emit SetMarketingFee(msg.sender, _marketingFeeBP);
    }


    function updateEmissionRate(uint256 _mxsPerBlock) external onlyOwner {
        massUpdatePools();
        mxsPerBlock = _mxsPerBlock;
        emit UpdateEmissionRate(msg.sender, _mxsPerBlock);
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) public onlyOwner {
        require(startBlock >= block.number, "updateStartBlock: Farm already started!"); //Added conditionnal check
        startBlock = _startBlock;
    }

    // Update the referral contract address by the owner
    function setReferralAddress(IMixSwapReferral _referral) external onlyOwner {
        referral = _referral;
        emit SetReferralAddress(msg.sender, _referral);
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) external onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points, max 15%");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                safeMxsTransfer(referrer, commissionAmount); //replaced the mint call. referral commission paid by Referee
                referral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }




}
