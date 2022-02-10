// SPDX-License-Identifier: MIT
import './interfaces/StorageInterfaceV5.sol';
pragma solidity 0.8.11;

contract GNSNftRewardsV6 {

    // Contracts (constant)
    StorageInterfaceV5 constant storageT = StorageInterfaceV5(0xaee4d11a16B2bc65EDD6416Fb626EB404a6D65BD);

    // Params (constant)
    uint constant ROUND_LENGTH = 50;

    // Params (adjustable)
    uint public triggerTimeout = 5;     // blocks
    uint public sameBlockLimit = 10;    // bots

    uint public firstP = 40;            // %
    uint public sameBlockP = 20;        // %
    uint public poolP = 40;             // %

    // Custom data types
    struct TriggeredLimit{ address first; address[] sameBlock; uint block; }
    struct TriggeredLimitId{ address trader; uint pairIndex; uint index; StorageInterfaceV5.LimitOrder order; }
    
    enum OpenLimitOrderType{ LEGACY, REVERSAL, MOMENTUM }

    // State
    uint public currentOrder = 1;                                           // current order in round
    uint public currentRound;                                               // current round (1 round = 50 orders)

    mapping(uint => uint) public roundTokens;                               // total token rewards for a round
    mapping(address => mapping(uint => uint)) public roundOrdersToClaim;    // orders to claim from a round (out of 50)

    mapping(address => uint) public tokensToClaim;                          // rewards other than pool (first & same block)
    
    mapping(
        address => mapping(
            uint => mapping(
                uint => mapping(
                    StorageInterfaceV5.LimitOrder => TriggeredLimit
                )
            )
        )
    ) public triggeredLimits;   // limits being triggered

    mapping(address => mapping(uint => mapping(uint => OpenLimitOrderType))) public openLimitOrderTypes;

    // Statistics
    mapping(address => uint) public tokensClaimed; // 1e18
    uint public tokensClaimedTotal; // 1e18

    // Events
    event NumberUpdated(string name, uint value);
    event PercentagesUpdated(uint firstP, uint sameBlockP, uint poolP);

    event TriggeredFirst(TriggeredLimitId id, address bot);
    event TriggeredSameBlock(TriggeredLimitId id, address bot);
    event TriggerUnregistered(TriggeredLimitId id);
    event TriggerRewarded(TriggeredLimitId id, address first, uint sameBlockCount, uint reward);
    
    event PoolTokensClaimed(address bot, uint fromRound, uint toRound, uint tokens);
    event TokensClaimed(address bot, uint tokens);

    constructor() { }

    // Modifiers
    modifier onlyGov(){ require(msg.sender == storageT.gov(), "GOV_ONLY"); _; }
    modifier onlyTrading(){ require(msg.sender == storageT.trading(), "TRADING_ONLY"); _; }
    modifier onlyCallbacks(){ require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY"); _; }

    // Manage params
    function updateTriggerTimeout(uint _triggerTimeout) external onlyGov{
        require(_triggerTimeout >= 5, "LESS_THAN_5");
        triggerTimeout = _triggerTimeout;
        emit NumberUpdated("triggerTimeout", _triggerTimeout);
    }
    function updateSameBlockLimit(uint _sameBlockLimit) external onlyGov{
        require(_sameBlockLimit >= 5, "LESS_THAN_5");
        sameBlockLimit = _sameBlockLimit;
        emit NumberUpdated("sameBlockLimit", _sameBlockLimit);
    }
    function updatePercentages(uint _firstP, uint _sameBlockP, uint _poolP) external onlyGov{
        require(_firstP + _sameBlockP + _poolP == 100, "SUM_NOT_100");

        firstP = _firstP;
        sameBlockP = _sameBlockP;
        poolP = _poolP;

        emit PercentagesUpdated(_firstP, _sameBlockP, _poolP);
    }

    // Triggers
    function storeFirstToTrigger(TriggeredLimitId calldata _id, address _bot) external onlyTrading{
        TriggeredLimit storage t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];

        t.first = _bot;
        delete t.sameBlock;
        t.block = block.number;

        emit TriggeredFirst(_id, _bot);
    }
    function storeTriggerSameBlock(TriggeredLimitId calldata _id, address _bot) external onlyTrading{
        TriggeredLimit storage t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];
        
        require(t.block == block.number, "TOO_LATE");
        require(t.sameBlock.length < sameBlockLimit, "SAME_BLOCK_LIMIT");
        
        t.sameBlock.push(_bot);
        
        emit TriggeredSameBlock(_id, _bot);
    }
    function unregisterTrigger(TriggeredLimitId calldata _id) external onlyCallbacks{
        delete triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];
        emit TriggerUnregistered(_id);
    }

    // Distribute rewards
    function distributeNftReward(TriggeredLimitId calldata _id, uint _reward) external onlyCallbacks{
        TriggeredLimit memory t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];

        require(t.block > 0, "NOT_TRIGGERED");

        tokensToClaim[t.first] += _reward * firstP / 100;

        if(t.sameBlock.length > 0){
            uint sameBlockReward = _reward * sameBlockP / t.sameBlock.length / 100;
            for(uint i = 0; i < t.sameBlock.length; i++){
                tokensToClaim[t.sameBlock[i]] += sameBlockReward;
            }
        }

        roundTokens[currentRound] += _reward * poolP / 100;
        roundOrdersToClaim[t.first][currentRound] ++;

        if(currentOrder == ROUND_LENGTH){
            currentOrder = 1;
            currentRound ++;
        }else{
            currentOrder ++;
        }

        emit TriggerRewarded(_id, t.first, t.sameBlock.length, _reward);
    }

    // Claim rewards
    function claimPoolTokens(uint _fromRound, uint _toRound) external{
        require(_toRound >= _fromRound, "TO_BEFORE_FROM");
        require(_toRound < currentRound, "TOO_EARLY");

        uint tokens;

        for(uint i = _fromRound; i <= _toRound; i++){
            tokens += roundOrdersToClaim[msg.sender][i]*roundTokens[i]/ROUND_LENGTH;
            roundOrdersToClaim[msg.sender][i] = 0;
        }

        require(tokens > 0, "NOTHING_TO_CLAIM");
        storageT.handleTokens(msg.sender, tokens, true);

        tokensClaimed[msg.sender] += tokens;
        tokensClaimedTotal += tokens;
        
        emit PoolTokensClaimed(msg.sender, _fromRound, _toRound, tokens);
    }
    function claimTokens() external{
        uint tokens = tokensToClaim[msg.sender];
        require(tokens > 0, "NOTHING_TO_CLAIM");

        tokensToClaim[msg.sender] = 0;
        storageT.handleTokens(msg.sender, tokens, true);

        tokensClaimed[msg.sender] += tokens;
        tokensClaimedTotal += tokens;

        emit TokensClaimed(msg.sender, tokens);
    }

    // Manage open limit order types
    function setOpenLimitOrderType(address _trader, uint _pairIndex, uint _index, OpenLimitOrderType _type) external onlyTrading{
        openLimitOrderTypes[_trader][_pairIndex][_index] = _type;
    }

    // Getters
    function triggered(TriggeredLimitId calldata _id) external view returns(bool){
        TriggeredLimit memory t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];
        return t.block > 0;
    }
    function timedOut(TriggeredLimitId calldata _id) external view returns(bool){
        TriggeredLimit memory t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];
        return t.block > 0 && block.number - t.block >= triggerTimeout;
    }
    function sameBlockTriggers(TriggeredLimitId calldata _id) external view returns(address[] memory){
        return triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order].sameBlock;
    }
}