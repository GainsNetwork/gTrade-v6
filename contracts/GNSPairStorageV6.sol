// SPDX-License-Identifier: MIT
import './interfaces/StorageInterfaceV5.sol';
pragma solidity 0.8.11;

contract GNSPairsStorageV6 {

    // Contracts (constant)
    StorageInterfaceV5 constant storageT = StorageInterfaceV5(0xaee4d11a16B2bc65EDD6416Fb626EB404a6D65BD);

    // Params (constant)
    uint constant MIN_LEVERAGE = 2;
    uint constant MAX_LEVERAGE = 1000;

    // Custom data types
    enum FeedCalculation { DEFAULT, INVERT, COMBINE }
    struct Feed{ address feed1; address feed2; FeedCalculation feedCalculation; uint maxDeviationP; } // PRECISION (%)

    struct Pair{
        string from;
        string to;
        Feed feed;
        uint spreadP;               // PRECISION
        uint groupIndex;
        uint feeIndex;
    }
    struct Group{
        string name;
        bytes32 job;
        uint minLeverage;
        uint maxLeverage;
        uint maxCollateralP;        // % (of DAI vault current balance)
    }
    struct Fee{
        string name;
        uint openFeeP;              // PRECISION (% of leveraged pos)
        uint closeFeeP;             // PRECISION (% of leveraged pos)
        uint oracleFeeP;            // PRECISION (% of leveraged pos)
        uint nftLimitOrderFeeP;     // PRECISION (% of leveraged pos)
        uint referralFeeP;          // PRECISION (% of leveraged pos)
        uint minLevPosDai;          // 1e18 (collateral x leverage, useful for min fee)
    }

    // State
    uint public currentOrderId;

    uint public pairsCount;
    uint public groupsCount;
    uint public feesCount;

    mapping(uint => Pair) public pairs;
    mapping(uint => Group) public groups;
    mapping(uint => Fee) public fees;

    mapping(string => mapping(string => bool)) public isPairListed;

    mapping(uint => uint[2]) public groupsCollaterals; // (long, short)

    // Events
    event PairAdded(uint index, string from, string to);
    event PairUpdated(uint index);

    event GroupAdded(uint index, string name);
    event GroupUpdated(uint index);
    
    event FeeAdded(uint index, string name);
    event FeeUpdated(uint index);

    constructor(uint _currentOrderId) {
        require(_currentOrderId > 0, "ORDER_ID_0");
        currentOrderId = _currentOrderId;
    }

    // Modifiers
    modifier onlyGov(){ require(msg.sender == storageT.gov(), "GOV_ONLY"); _; }
    
    modifier groupListed(uint _groupIndex){
        require(groups[_groupIndex].minLeverage > 0, "GROUP_NOT_LISTED");
        _;
    }
    modifier feeListed(uint _feeIndex){
        require(fees[_feeIndex].openFeeP > 0, "FEE_NOT_LISTED");
        _;
    }

    modifier feedOk(Feed calldata _feed){
        require(_feed.maxDeviationP > 0 && _feed.feed1 != address(0), "WRONG_FEED");
        require(_feed.feedCalculation != FeedCalculation.COMBINE || _feed.feed2 != address(0), "FEED_2_MISSING");
        _;
    }
    modifier groupOk(Group calldata _group){
        require(_group.job != bytes32(0), "JOB_EMPTY");
        require(_group.minLeverage >= MIN_LEVERAGE && _group.maxLeverage <= MAX_LEVERAGE
            && _group.minLeverage < _group.maxLeverage, "WRONG_LEVERAGES");
        _;
    }
    modifier feeOk(Fee calldata _fee){
        require(_fee.openFeeP > 0 && _fee.closeFeeP > 0 && _fee.oracleFeeP > 0
            && _fee.nftLimitOrderFeeP > 0 && _fee.referralFeeP > 0 && _fee.minLevPosDai > 0, "WRONG_FEES");
        _;
    }

    // Manage pairs
    function addPair(Pair calldata _pair) public onlyGov feedOk(_pair.feed) groupListed(_pair.groupIndex) feeListed(_pair.feeIndex){
        require(!isPairListed[_pair.from][_pair.to], "PAIR_ALREADY_LISTED");
        
        pairs[pairsCount] = _pair;
        isPairListed[_pair.from][_pair.to] = true;
        
        emit PairAdded(pairsCount++, _pair.from, _pair.to);
    }
    function addPairs(Pair[] calldata _pairs) external{
        for(uint i = 0; i < _pairs.length; i++){
            addPair(_pairs[i]);
        }
    }
    function updatePair(uint _pairIndex, Pair calldata _pair) external onlyGov feedOk(_pair.feed) feeListed(_pair.feeIndex){
        Pair storage p = pairs[_pairIndex];
        require(isPairListed[p.from][p.to], "PAIR_NOT_LISTED");

        p.feed = _pair.feed;
        p.spreadP = _pair.spreadP;
        p.feeIndex = _pair.feeIndex;
        
        emit PairUpdated(_pairIndex);
    }

    // Manage groups
    function addGroup(Group calldata _group) external onlyGov groupOk(_group){
        groups[groupsCount] = _group;
        emit GroupAdded(groupsCount++, _group.name);
    }
    function updateGroup(uint _id, Group calldata _group) external onlyGov groupListed(_id) groupOk(_group){
        groups[_id] = _group;
        emit GroupUpdated(_id);
    }

    // Manage fees
    function addFee(Fee calldata _fee) external onlyGov feeOk(_fee){
        fees[feesCount] = _fee;
        emit FeeAdded(feesCount++, _fee.name);
    }
    function updateFee(uint _id, Fee calldata _fee) external onlyGov feeListed(_id) feeOk(_fee){
        fees[_id] = _fee;
        emit FeeUpdated(_id);
    }

    // Update collateral open exposure for a group (callbacks)
    function updateGroupCollateral(uint _pairIndex, uint _amount, bool _long, bool _increase) external{
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");

        uint[2] storage collateralOpen = groupsCollaterals[pairs[_pairIndex].groupIndex];
        uint index = _long ? 0 : 1;

        if(_increase){
            collateralOpen[index] += _amount;
        }else{
            collateralOpen[index] = collateralOpen[index] > _amount ? collateralOpen[index] - _amount : 0;
        }
    }

    // Fetch relevant info for order (aggregator)
    function pairJob(uint _pairIndex) external returns(string memory, string memory, bytes32, uint){
        require(msg.sender == address(storageT.priceAggregator()), "AGGREGATOR_ONLY");
        
        Pair memory p = pairs[_pairIndex];
        require(isPairListed[p.from][p.to], "PAIR_NOT_LISTED");
        
        return (p.from, p.to, groups[p.groupIndex].job, currentOrderId++);
    }

    // Getters (pairs & groups)
    function pairFeed(uint _pairIndex) external view returns(Feed memory){
        return pairs[_pairIndex].feed;
    }
    function pairSpreadP(uint _pairIndex) external view returns(uint){
        return pairs[_pairIndex].spreadP;
    }
    function pairMinLeverage(uint _pairIndex) external view returns(uint){
        return groups[pairs[_pairIndex].groupIndex].minLeverage;
    }
    function pairMaxLeverage(uint _pairIndex) external view returns(uint){
        return groups[pairs[_pairIndex].groupIndex].maxLeverage;
    }
    function groupMaxCollateral(uint _pairIndex) external view returns(uint){
        return groups[pairs[_pairIndex].groupIndex].maxCollateralP*storageT.vault().currentBalanceDai()/100;
    }
    function groupCollateral(uint _pairIndex, bool _long) external view returns(uint){
        return groupsCollaterals[pairs[_pairIndex].groupIndex][_long ? 0 : 1];
    }
    function guaranteedSlEnabled(uint _pairIndex) external view returns(bool){
        return pairs[_pairIndex].groupIndex == 0; // crypto only
    }

    // Getters (fees)
    function pairOpenFeeP(uint _pairIndex) external view returns(uint){ 
        return fees[pairs[_pairIndex].feeIndex].openFeeP;
    }
    function pairCloseFeeP(uint _pairIndex) external view returns(uint){ 
        return fees[pairs[_pairIndex].feeIndex].closeFeeP; 
    }
    function pairOracleFeeP(uint _pairIndex) external view returns(uint){ 
        return fees[pairs[_pairIndex].feeIndex].oracleFeeP; 
    }
    function pairNftLimitOrderFeeP(uint _pairIndex) external view returns(uint){ 
        return fees[pairs[_pairIndex].feeIndex].nftLimitOrderFeeP; 
    }
    function pairReferralFeeP(uint _pairIndex) external view returns(uint){ 
        return fees[pairs[_pairIndex].feeIndex].referralFeeP; 
    }
    function pairMinLevPosDai(uint _pairIndex) external view returns(uint){
        return fees[pairs[_pairIndex].feeIndex].minLevPosDai;
    }

    // Getters (backend)
    function pairsBackend(uint _index) external view returns(Pair memory, Group memory, Fee memory){
        Pair memory p = pairs[_index];
        return (p, groups[p.groupIndex], fees[p.feeIndex]);
    }
}