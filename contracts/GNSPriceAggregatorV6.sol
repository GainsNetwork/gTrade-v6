// SPDX-License-Identifier: MIT
import '@chainlink/contracts/src/v0.8/ChainlinkClient.sol';
import './interfaces/CallbacksInterfaceV6.sol';
import './interfaces/ChainlinkFeedInterfaceV5.sol';
import './interfaces/LpInterfaceV5.sol';
import './interfaces/StorageInterfaceV5.sol';
pragma solidity 0.8.11;

contract GNSPriceAggregatorV6 is ChainlinkClient {
    using Chainlink for Chainlink.Request;
    
    // Contracts (constant)
    StorageInterfaceV5 constant storageT = StorageInterfaceV5(0xaee4d11a16B2bc65EDD6416Fb626EB404a6D65BD);
    LpInterfaceV5 constant tokenDaiLp = LpInterfaceV5(0x6E53cB6942e518376E9e763554dB1A45DDCd25c4);

    // Contracts (adjustable)
    PairsStorageInterfaceV6 public pairsStorage;
    address public nftRewards;

    // Params (constant)
    uint constant PRECISION = 1e10;
    uint constant MAX_ORACLE_NODES = 20;
    uint constant MIN_ANSWERS = 3;

    // Params (adjustable)
    uint public minAnswers = 3;
    uint public linkPriceDai = 20;   // $

    // Custom data types
    enum OrderType { MARKET_OPEN, MARKET_CLOSE, LIMIT_OPEN, LIMIT_CLOSE, UPDATE_SL }
    struct Order{ uint pairIndex; OrderType orderType; uint linkFee; bool initiated; }
    struct PendingSl{ address trader; uint pairIndex; uint index; uint openPrice; bool buy; uint newSl; }

    // State
    address[] public nodes;

    mapping(uint => Order) public orders;
    mapping(bytes32 => uint) public orderIdByRequest;
    mapping(uint => uint[]) public ordersAnswers;

    mapping(uint => PendingSl) public pendingSlOrders;

    // Events
    event AddressUpdated(string name, address a);
    event NumberUpdated(string name, uint value);

    event NodeAdded(uint index, address a);
    event NodeReplaced(uint index, address oldNode, address newNode);
    event NodeRemoved(uint index, address oldNode);

    event PriceReceived(
        bytes32 request,
        uint orderId,
        address node,
        uint pairIndex,
        uint price,
        uint referencePrice,
        uint linkFee
    );

    constructor(address[] memory _nodes, PairsStorageInterfaceV6 _pairsStorage, address _nftRewards) {
        require(_nodes.length > 0 && address(_pairsStorage) != address(0) && _nftRewards != address(0), "WRONG_PARAMS");

        nodes = _nodes;
        pairsStorage = _pairsStorage;
        nftRewards = _nftRewards;
        
        setChainlinkToken(0xb0897686c545045aFc77CF20eC7A532E3120E0F1);
    }

    // Modifiers
    modifier onlyGov(){ require(msg.sender == storageT.gov(), "GOV_ONLY"); _; }
    modifier onlyTrading(){ require(msg.sender == storageT.trading(), "TRADING_ONLY"); _; }

    // Manage contracts
    function updatePairsStorage(PairsStorageInterfaceV6 _pairsStorage) external onlyGov{
        require(address(_pairsStorage) != address(0), "VALUE_0");
        pairsStorage = _pairsStorage;
        emit AddressUpdated("pairsStorage", address(_pairsStorage));
    }
    function updateNftRewards(address _nftRewards) external onlyGov{
        require(_nftRewards != address(0), "VALUE_0");
        nftRewards = _nftRewards;
        emit AddressUpdated("nftRewards", _nftRewards);
    }

    // Manage params
    function updateMinAnswers(uint _minAnswers) external onlyGov{
        require(_minAnswers >= MIN_ANSWERS, "MIN_ANSWERS");
        require(_minAnswers % 2 == 1, "EVEN");
        minAnswers = _minAnswers;
        emit NumberUpdated("minAnswers", _minAnswers);
    }
    function updateLinkPriceDai(uint _newPrice) external onlyGov{
        require(_newPrice > 0, "VALUE_0");
        linkPriceDai = _newPrice;
        emit NumberUpdated("linkPriceDai", _newPrice);
    }

    // Manage nodes
    function addNode(address _a) external onlyGov{
        require(_a != address(0), "VALUE_0");
        require(nodes.length < MAX_ORACLE_NODES, "MAX_ORACLE_NODES");
        for(uint i = 0; i < nodes.length; i++){ require(nodes[i] != _a, "ALREADY_LISTED"); }

        nodes.push(_a);

        emit NodeAdded(nodes.length-1, _a);
    }
    function replaceNode(uint _index, address _a) external onlyGov{
        require(_index < nodes.length, "WRONG_INDEX");
        require(_a != address(0), "VALUE_0");

        emit NodeReplaced(_index, nodes[_index], _a);

        nodes[_index] = _a;
    }
    function removeNode(uint _index) external onlyGov{
        require(_index < nodes.length, "WRONG_INDEX");

        emit NodeRemoved(_index, nodes[_index]);

        nodes[_index] = nodes[nodes.length-1];
        nodes.pop();
    }

    // On-demand price request to oracles network
    function getPrice(
        uint _pairIndex,
        OrderType _orderType,
        uint _leveragedPosDai
    ) external onlyTrading returns(uint){

        (string memory from, string memory to, bytes32 job, uint orderId) = pairsStorage.pairJob(_pairIndex);
        
        Chainlink.Request memory linkRequest = buildChainlinkRequest(job, address(this), this.fulfill.selector);
        linkRequest.add("from", from);
        linkRequest.add("to", to);

        uint linkFeePerNode = linkFee(_pairIndex, _leveragedPosDai) / nodes.length;
        
        orders[orderId] = Order(
            _pairIndex, 
            _orderType, 
            linkFeePerNode,
            true
        );

        for(uint i = 0; i < nodes.length; i ++){
            orderIdByRequest[sendChainlinkRequestTo(nodes[i], linkRequest, linkFeePerNode)] = orderId;
        }

        return orderId;
    }

    // Fulfill on-demand price requests
    function fulfill(bytes32 _requestId, uint _price) external recordChainlinkFulfillment(_requestId){

        uint orderId = orderIdByRequest[_requestId];
        Order storage r = orders[orderId];

        delete orderIdByRequest[_requestId];

        if(r.initiated){

            uint[] storage answers = ordersAnswers[orderId];
            uint feedPrice;

            PairsStorageInterfaceV6.Feed memory f = pairsStorage.pairFeed(r.pairIndex);
            (, int feedPrice1, , , ) = ChainlinkFeedInterfaceV5(f.feed1).latestRoundData();

            if(f.feedCalculation == PairsStorageInterfaceV6.FeedCalculation.DEFAULT){
                feedPrice = uint(feedPrice1*int(PRECISION)/1e8);
            }else if(f.feedCalculation == PairsStorageInterfaceV6.FeedCalculation.INVERT){
                feedPrice = uint(int(PRECISION)*1e8/feedPrice1);
            }else{
                (, int feedPrice2, , , ) = ChainlinkFeedInterfaceV5(f.feed2).latestRoundData();
                feedPrice = uint(feedPrice1*int(PRECISION)/feedPrice2);
            }

            uint priceDiff = _price >= feedPrice ? (_price - feedPrice) : (feedPrice - _price);
            if(_price == 0 || priceDiff * PRECISION * 100 / feedPrice <= f.maxDeviationP){

                answers.push(_price);
                emit PriceReceived(_requestId, orderId, msg.sender, r.pairIndex, _price, feedPrice, r.linkFee);

                if(answers.length == minAnswers){

                    CallbacksInterfaceV6.AggregatorAnswer memory a = CallbacksInterfaceV6.AggregatorAnswer(
                        orderId,
                        median(answers),
                        pairsStorage.pairSpreadP(r.pairIndex)
                    );

                    CallbacksInterfaceV6 c = CallbacksInterfaceV6(storageT.callbacks());

                    if(r.orderType == OrderType.MARKET_OPEN){
                        c.openTradeMarketCallback(a);
                    }else if(r.orderType == OrderType.MARKET_CLOSE){
                        c.closeTradeMarketCallback(a);
                    }else if(r.orderType == OrderType.LIMIT_OPEN){
                        c.executeNftOpenOrderCallback(a);
                    }else if(r.orderType == OrderType.LIMIT_CLOSE){
                        c.executeNftCloseOrderCallback(a);
                    }else{
                        c.updateSlCallback(a);
                    }

                    delete orders[orderId];
                    delete ordersAnswers[orderId];
                }
            }
        }
    }

    // Calculate LINK fee for each request
    function linkFee(uint _pairIndex, uint _leveragedPosDai) public view returns(uint){
        return pairsStorage.pairOracleFeeP(_pairIndex) * _leveragedPosDai / linkPriceDai / PRECISION / 100;
    }

    // Manage pending SL orders
    function storePendingSlOrder(uint orderId, PendingSl calldata p) external onlyTrading{
        pendingSlOrders[orderId] = p;
    }
    function unregisterPendingSlOrder(uint orderId) external{
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");
        delete pendingSlOrders[orderId];
    }

    // Claim back LINK tokens (if contract will be replaced for example)
    function claimBackLink() external onlyGov{
        TokenInterfaceV5 link = storageT.linkErc677();
        link.transfer(storageT.gov(), link.balanceOf(address(this)));
    }

    // Token price & liquidity
    function tokenDaiReservesLp() public view returns(uint, uint){
        (uint112 reserves0, uint112 reserves1, ) = tokenDaiLp.getReserves();
        return tokenDaiLp.token0() == address(storageT.token()) ? (reserves0, reserves1) : (reserves1, reserves0);
    }
    function tokenPriceDai() external view returns(uint){
        (uint reserveToken, uint reserveDai) = tokenDaiReservesLp();
        return reserveDai * PRECISION / reserveToken;
    }

    // Median function
    function swap(uint[] memory array, uint i, uint j) private pure { (array[i], array[j]) = (array[j], array[i]); }
    function sort(uint[] memory array, uint begin, uint end) private pure {
        if (begin >= end) { return; }
        uint j = begin;
        uint pivot = array[j];
        for (uint i = begin + 1; i < end; ++i) {
            if (array[i] < pivot) {
                swap(array, i, ++j);
            }
        }
        swap(array, begin, j);
        sort(array, begin, j);
        sort(array, j + 1, end);
    }
    function median(uint[] memory array) private pure returns(uint) {
        sort(array, 0, array.length);
        return array.length % 2 == 0 ? (array[array.length/2-1]+array[array.length/2])/2 : array[array.length/2];
    }

    // Storage v5 compatibility
    function openFeeP(uint _pairIndex) external view returns(uint){
        return pairsStorage.pairOpenFeeP(_pairIndex);
    }
}