// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libs/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IReferral.sol";
import "./libs/Ownable.sol";
import "./libs/ReentrancyGuard.sol";
import "./thetoken.sol";

contract MasterChefV2 is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.

        // We do some fancy math here. Basically, any point in time, the amount of token
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. TOKENs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that TOKENs distribution occurs.
        uint256 accTokenPerShare; // Accumulated TOKENs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points

    }

    // THE TOKEN!
    TheToken public token;
    // Dev address.
    address public devaddr;
    // TOKEN tokens created per block.
    uint256 public tokenPerBlock;
    // TOKEN minting rate for dev.
    uint256 public devTokenRate = 0;
    // Bonus multiplier for early TOKEN makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when TOKEN mining starts.
    uint256 public startBlock;
    // Token referral contract address.
    IReferral public tokenReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 0;


    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event SetDevTokenRate(address indexed user, uint256 devTokenRate);
    event UpdateEmissionRate(address indexed user, uint256 tokenPerBlock);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        TheToken _token,
        address _devaddr,
        address _feeAddress,
        uint256 _tokenPerBlock,
        uint256 _startBlock
    ) public {
        token = _token;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        tokenPerBlock = _tokenPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IBEP20 => bool) public poolExistence;
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new LP to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP,  bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 1000, "add: invalid deposit fee basis points. max 10%");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accTokenPerShare : 0,
        depositFeeBP : _depositFeeBP

        }));
    }

    // Update the given pool's TOKEN allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP,  bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 1000, "set: invalid deposit fee basis points. max 10%");

        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;

    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending TOKENs on frontend.
    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accTokenPerShare = accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
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
        uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        // Mint for dev if devTokenRate is enable ( > 0). Default is disable. If enable max capped at 10%
        if (devTokenRate > 0) {
            token.mint(devaddr, tokenReward.mul(devTokenRate).div(10000));
        }

        token.mint(address(this), tokenReward);
        pool.accTokenPerShare = pool.accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for TOKEN allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer ) public nonReentrant {
        require(block.number > startBlock, "farm not running"); //Added for EDXA IFO purpose

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        // Record for new referral
        if (_amount > 0 && address(tokenReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            tokenReferral.recordReferral(msg.sender, _referrer);
        }

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {

                safeTokenTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);

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

        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    // If harvestLock is active, only can withdraw after harvest lock end.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        require(block.number > startBlock, "farm not running"); //Added for EDXA IFO purpose

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {

            safeTokenTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe TOKEN transfer function, just in case if rounding error causes pool to not have enough TOKENs.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > tokenBal) {
            transferSuccess = token.transfer(_to, tokenBal);
        } else {
            transferSuccess = token.transfer(_to, _amount);
        }
        require(transferSuccess, "safeTokenTransfer: transfer failed");
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _tokenPerBlock) public onlyOwner {
        massUpdatePools();
        tokenPerBlock = _tokenPerBlock;
        emit UpdateEmissionRate(msg.sender, _tokenPerBlock);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: invalid user ");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    // Update dev token rate. Max is 10%. Default is disable (0)
    function updateDevTokenRate(uint256 _devTokenRate) public {
        require(msg.sender == devaddr, "dev: only dev can update");
        require(_devTokenRate <= 1000, "setDevTokenRate: invalid rate basis points. max 10%");
        devTokenRate = _devTokenRate;
        emit SetDevTokenRate(msg.sender, _devTokenRate);
    }

    // Update deposit fee address
    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }
    // Update the token referral contract address by the owner
    function setTokenReferral(IReferral _tokenReferral) public onlyOwner {
        tokenReferral = _tokenReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= 1000, "setReferralCommissionRate: invalid referral commission rate basis points. max 10%");
        referralCommissionRate = _referralCommissionRate;
    }


    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(tokenReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = tokenReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                token.mint(referrer, commissionAmount);
                tokenReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
}
