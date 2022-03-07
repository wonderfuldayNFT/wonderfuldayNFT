pragma solidity >=0.8.0;
import "./openzeppelin-contracts/contracts/access/Ownable.sol";
import "./openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "./openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import "./openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import "./openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "./openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract Market is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    event CreateOrder(uint256 indexed orderId, address seller, address goods, bool is1155, uint256 tokenId, uint256 quantity, address currency, uint256 price);
    event ChangePrice(uint256 indexed orderId, address currency, uint256 price);
    event CancelOrder(uint256 indexed orderId);
    event Buy(uint256 indexed orderId, address buyer, uint256 totalFee, uint256 userFee);
    
    struct Order {
        address seller;
        address goods;      // token address of goods (in whitelist)
        bool is1155;        // 1155 or 721
        uint256 tokenId;    // 1155 => id
        uint256 quantity;   // 721 => 1
        address currency;   // ERC20 or ETH
        uint256 price;
        address buyer;
        uint256 orderTime;
        uint256 tradeTime;
    }
    
    struct Fee {
        address feeTo;
        uint256 feeRate;
    }
    
    struct GoodsInfo {
        address currency;
        bool is1155;
        uint256 orderReward;
        uint256 tradeReward;
        uint256 rewardStartDay;
        uint256 rewardEndDay;
    }
    
    struct TradeInfo {
        uint256 orderNumber;
        uint256 tradeNumber;
    }
    
    Fee[] public fees;
    uint256 public totalFeeRate;
    uint256 public constant FEE_BASE = 10000;
    Order[] public orders;
    mapping(address => GoodsInfo) public goodsInfos;
    EnumerableSet.AddressSet private whiteGoods;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public immutable StartTime;
    mapping(uint256 => mapping(address => TradeInfo)) public trades;
    mapping(address => EnumerableSet.UintSet) private userOrders;
    mapping(address => EnumerableSet.UintSet) private userTrades;
    IERC20 public immutable RewardToken;
    uint256 private constant decimals = 1e18;
    
    modifier hasOrder(uint256 orderId) {
        require(orderId < orders.length, "Market:orderId not exists");
        _;
    }
    
    constructor(IERC20 rewardToken){
        StartTime = block.timestamp;
        RewardToken = rewardToken;
    }
    
    function getDay(uint256 timesatmp) pure public returns(uint256){
        return timesatmp/86400;
    }

    function addGoods(address goods, address currency, bool is1155, uint256 orderReward, uint256 tradeReward, uint256 rewardStartDay, uint256 rewardEndDay) public onlyOwner {
        if(!whiteGoods.contains(goods)){
            whiteGoods.add(goods);
        }
        goodsInfos[goods].currency = currency;
        goodsInfos[goods].is1155 = is1155;
        goodsInfos[goods].orderReward = orderReward;
        goodsInfos[goods].rewardStartDay = tradeReward;
        goodsInfos[goods].rewardEndDay = rewardStartDay;
        goodsInfos[goods].tradeReward = rewardEndDay;
    }
    
    function removeGoods(address goods) public onlyOwner {
        if(whiteGoods.contains(goods)){
            whiteGoods.remove(goods);
        }
        goodsInfos[goods].currency = address(0);
        goodsInfos[goods].is1155 = false;
        goodsInfos[goods].orderReward = 0;
        goodsInfos[goods].rewardStartDay = 0;
        goodsInfos[goods].rewardEndDay = 0;
        goodsInfos[goods].tradeReward = 0;
    }
    
    function batchAddGoods(address[] memory goods, address[] memory currency, bool[] memory is1155, uint256[] memory orderReward, uint256[] memory tradeReward, uint256[] memory rewardStartDay, uint256[] memory rewardEndDay) public {
        require(goods.length == currency.length && goods.length == is1155.length && goods.length == orderReward.length && goods.length == tradeReward.length && goods.length == rewardStartDay.length && goods.length == rewardEndDay.length, "Market:length not match");
        for(uint256 i = 0; i < goods.length; i++){
            addGoods(goods[i], currency[i], is1155[i], orderReward[i], tradeReward[i], rewardStartDay[i], rewardEndDay[i]);
        }
    }
    
    function batchRemoveGoods(address[] memory goods) public {
        for(uint256 i = 0; i < goods.length; i++){
            removeGoods(goods[i]);
        }
    }
    
    function getGoodsLength() public view returns(uint256){
        return whiteGoods.length();
    }
    
    function isGoods(address goods) public view returns(bool){
        return whiteGoods.contains(goods);
    }
    
    function getGoods(uint256 index) public view returns(address){
        require(index < whiteGoods.length(), "Market:invalid index");
        return whiteGoods.at(index);
    }
    
    function setFees(uint256 _totalFeeRate, address[] memory feeTos, uint256[] memory feeRates) public onlyOwner {
        require(feeTos.length == feeRates.length, "Market:length not match");
        delete fees;
        uint256 sum = 0;
        for(uint256 i = 0; i < feeTos.length; i++){
            sum += feeRates[i];
            fees.push(Fee(feeTos[i], feeRates[i]));
        }
        require(sum <= _totalFeeRate && _totalFeeRate <= FEE_BASE, "Market:feerate overflow");
        totalFeeRate = _totalFeeRate;
    }
    
    function lengthOrder() public view returns (uint256) {
        return orders.length;
    }
    
    function listOrder(uint256 start, uint256 limit) public view returns (Order[] memory) {
        Order[] memory o = new Order[](limit);
        for(uint256 i = 0; i < limit && start < orders.length; i++) {
            o[i] = orders[start++];
        }
        return o;
    }
    
    function createOrder(address goods, uint256 tokenId, uint256 quantity, uint256 price) public nonReentrant() {
        GoodsInfo memory goodsInfo = goodsInfos[goods];
        require(whiteGoods.contains(goods) && goodsInfo.currency != address(0), "Market:invalid goods");
        if(!goodsInfo.is1155){
            require(quantity == 1, "Market:ERC721 only support one tokenId");
        }
        uint256 amount = price * quantity;
        require(amount > 0, "Market:amount is 0");
        _transferNFT(goods, goodsInfo.is1155, tokenId, quantity, msg.sender, address(this));
        uint256 orderId = orders.length;
        orders.push(Order(msg.sender, goods, goodsInfo.is1155, tokenId, quantity, goodsInfo.currency, price, address(0), block.timestamp, 0));
        trades[getDay(block.timestamp)][goods].orderNumber++;
        userOrders[msg.sender].add(orderId);
        emit CreateOrder(orderId, msg.sender, goods, goodsInfo.is1155, tokenId, quantity, goodsInfo.currency, price);
    }
    
    function changePrice(uint256 orderId, uint256 price) public nonReentrant() hasOrder(orderId) {
        Order storage o = orders[orderId];
        require(price > 0, "Market:price is 0");
        require(msg.sender == o.seller, "Market:not seller");
        GoodsInfo memory goodsInfo = goodsInfos[o.goods];
        require(whiteGoods.contains(o.goods) && goodsInfo.currency != address(0), "Market:invalid goods");
        require(o.buyer == address(0), "Market:already sold");
        o.price = price;
        o.currency = goodsInfo.currency;
        emit ChangePrice(orderId, goodsInfo.currency, price);
    }
    
    function cancelOrder(uint256 orderId) public nonReentrant() hasOrder(orderId) {
        Order storage o = orders[orderId];
        require(msg.sender == o.seller, "Market:not seller");
        require(o.buyer == address(0), "Market:already sold");
        o.buyer = msg.sender;
        o.orderTime = 0;
        if(userOrders[msg.sender].contains(orderId)){
            userOrders[msg.sender].remove(orderId);
        }
        _transferNFT(o.goods, o.is1155, o.tokenId, o.quantity, address(this), msg.sender);
        emit CancelOrder(orderId);
    }
    
    function buy(uint256 orderId) public payable nonReentrant() hasOrder(orderId) {
        Order storage o = orders[orderId];
        require(msg.sender != o.seller, "Market:buyer is seller");
        require(o.buyer == address(0), "Market:already sold");
        o.buyer = msg.sender;
        o.tradeTime = block.timestamp;
        uint256 amount = o.price * o.quantity;
        _recvCurrency(o.currency, msg.sender, amount);
        uint256 fee = amount * totalFeeRate / FEE_BASE;
        uint256 totalFee = fee;
        for(uint256 i = 0; i < fees.length; i++){
            uint256 f = amount * fees[i].feeRate / FEE_BASE;
            _sendCurrency(o.currency, fees[i].feeTo, f);
            fee -= f;
        }
        trades[getDay(block.timestamp)][o.goods].tradeNumber += 1;
        userTrades[msg.sender].add(orderId);
        _sendCurrency(o.currency, o.seller, amount - totalFee);
        _transferNFT(o.goods, o.is1155, o.tokenId, o.quantity, address(this), msg.sender);
        emit Buy(orderId, msg.sender, totalFee, fee);
    }
    
    function _transferNFT(address token, bool is1155, uint256 tokenId, uint256 quantity, address from, address to) internal {
        if(is1155){
            IERC1155(token).safeTransferFrom(from, to, tokenId, quantity, "");
        }else{
            IERC721(token).safeTransferFrom(from, to, tokenId);
        }
    }
    
    function _recvCurrency(address token, address from, uint256 amount) internal {
        if(token == ETH){
            require(msg.value == amount, "Market:invalid ETH amount");
        }else if(amount > 0){
            IERC20(token).safeTransferFrom(from, address(this), amount);
        }
    }
    
    function _sendCurrency(address token, address to, uint256 amount) internal {
        if(amount == 0){
            return;
        }
        if(token == ETH){
            payable(to).transfer(amount);
        }else{
            IERC20(token).safeTransfer(to, amount);
        }
    }
    
    function orderInfo(address user, uint256 start, uint256 limit) view public returns(uint256 size, uint256[] memory _orders, uint256 confirmed, uint256 pending){
        EnumerableSet.UintSet storage set = userOrders[user];
        size = set.length();
        if(start + limit > size){
            limit = size;
        }
        _orders = new uint256[](limit);
        for(uint256 i = 0; i < limit; i++){
            _orders[i] = set.at(start);
            Order memory order = orders[_orders[i]];
            uint256 optDay = getDay(order.orderTime);
            uint256 nowDay = getDay(block.timestamp);
            GoodsInfo memory goods = goodsInfos[order.goods];
            uint256 number = trades[optDay][order.goods].orderNumber;
            uint256 reward = goods.orderReward;
            if(reward > 0 && goods.rewardStartDay <= optDay && goods.rewardEndDay >= optDay && number > 0){
                if(optDay < nowDay){
                    confirmed += reward * decimals / number;
                }else{
                    pending += reward * decimals / number;
                }
            }
        }
        confirmed /= decimals;
        pending /= decimals;
    }
    
    function tradeInfo(address user, uint256 start, uint256 limit) view public returns(uint256 size, uint256[] memory _orders, uint256 confirmed, uint256 pending){
        EnumerableSet.UintSet storage set = userTrades[user];
        size = set.length();
        if(start + limit > size){
            limit = size;
        }
        _orders = new uint256[](limit);
        for(uint256 i = 0; i < limit; i++){
            _orders[i] = set.at(start);
            Order memory order = orders[_orders[i]];
            uint256 optDay = getDay(order.tradeTime);
            uint256 nowDay = getDay(block.timestamp);
            GoodsInfo memory goods = goodsInfos[order.goods];
            uint256 number = trades[optDay][order.goods].tradeNumber;
            uint256 reward = goods.tradeReward;
            if(reward > 0 && goods.rewardStartDay <= optDay && goods.rewardEndDay >= optDay && number > 0){
                if(optDay < nowDay){
                    confirmed += reward * decimals / number;
                }else{
                    pending += reward * decimals / number;
                }
            }
        }
        confirmed /= decimals;
        pending /= decimals;
    }
    
    function withdrawOrderReward(uint256 limit) external nonReentrant{
        EnumerableSet.UintSet storage set = userOrders[msg.sender];
        if(limit > set.length()){
            limit = set.length();
        }
        uint256 confirmed = 0;
        uint256 left = 0;
        for(uint256 i = 0; i < limit; i++){
            uint256 _order = set.at(left);
            Order memory order = orders[_order];
            uint256 optDay = getDay(order.orderTime);
            uint256 nowDay = getDay(block.timestamp);
            GoodsInfo memory goods = goodsInfos[order.goods];
            uint256 number = trades[optDay][order.goods].orderNumber;
            uint256 reward = goods.orderReward;
            if(optDay < nowDay){
                if(reward > 0 && goods.rewardStartDay <= optDay && goods.rewardEndDay >= optDay && number > 0){
                    confirmed += reward * decimals / number;
                }
                set.remove(_order);
            }else{
                left++;
            }
        }
        confirmed /= decimals;
        if(confirmed > 0){
            RewardToken.safeTransfer(msg.sender, confirmed);
        }
    }
    
    function withdrawTradeReward(uint256 limit) external nonReentrant{
        EnumerableSet.UintSet storage set = userTrades[msg.sender];
        if(limit > set.length()){
            limit = set.length();
        }
        uint256 confirmed = 0;
        uint256 left = 0;
        for(uint256 i = 0; i < limit; i++){
            uint256 _order = set.at(left);
            Order memory order = orders[_order];
            uint256 optDay = getDay(order.tradeTime);
            uint256 nowDay = getDay(block.timestamp);
            GoodsInfo memory goods = goodsInfos[order.goods];
            uint256 number = trades[optDay][order.goods].tradeNumber;
            uint256 reward = goods.tradeReward;
            if(optDay < nowDay){
                if(reward > 0 && goods.rewardStartDay <= optDay && goods.rewardEndDay >= optDay && number > 0){
                    confirmed += reward * decimals / number;
                }
                set.remove(_order);
            }else{
                left++;
            }
        }
        confirmed /= decimals;
        if(confirmed > 0){
            RewardToken.safeTransfer(msg.sender, confirmed);
        }
    }
    
    function onERC721Received(address, address, uint256, bytes memory) pure public returns (bytes4) {
        return this.onERC721Received.selector;
    }
    
    function onERC1155Received(address, address, uint256, uint256, bytes memory) pure public returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) pure public returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    receive() external payable {}
    
    function claimCurrency(address token, address to, uint256 amount) public onlyOwner {
        _sendCurrency(token, to, amount);
    }
}