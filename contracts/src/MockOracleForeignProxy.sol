pragma solidity 0.8.24;

import {KlerosOracle} from "./KlerosOracle.sol";
import {IHomeProxy} from "./MockOracleHomeProxy.sol";

interface IForeignProxy {
    function reportAnswer(bytes32 _questionID, bytes32 _answer, address _bridge) external;
    function receiveQuestion(uint256 _chainID, bytes32 _questionID,  string memory _questionData, uint256 _timeout, uint256 _openingTime, uint256 _minBond) external;
}

// Proxy on a chain with V2 arbitrator (e.g Arbitrum)
// Foreign proxy receives the question and relays it to Oracle. Receives the answer and relays it to home proxy
// Note that per each supported chain there is one ForeignProxy-HomeProxy pair. And each pair can support multiple bridge types.
// At this stage bridging mechanism is unfinished and simplified.
contract MockOracleForeignProxy is IForeignProxy {
    KlerosOracle klerosOracle;
    IHomeProxy homeProxy;
    mapping(address bridge => bool) public bridgeWhitelist;

    constructor(IHomeProxy _homeProxy, KlerosOracle _klerosOracle, address[] memory _bridges) {
        homeProxy = _homeProxy;
        klerosOracle = _klerosOracle;
        for (uint256 i = 0; i < _bridges.length; i++) {
            bridgeWhitelist[_bridges[i]] = true;
        }
    }

    function receiveQuestion(uint256 _chainID, bytes32 _questionID,  string memory _questionData, uint256 _timeout, uint256 _openingTime, uint256 _minBond) external {
        if(!bridgeWhitelist[msg.sender]) revert(); 
        // TODO: check that the sender on home chain is home proxy.
        // TODO: relay msg.value
        klerosOracle.askQuestion(_chainID, _questionID, _questionData, _timeout, _openingTime, _minBond);
    }

    // TODO: add separate functions for each bridge type?

    function reportAnswer(bytes32 _questionID, bytes32 _answer, address _bridge) external {
        if(msg.sender != address(klerosOracle)) revert();
        if(!bridgeWhitelist[_bridge]) revert();

        bytes4 methodSelector = IHomeProxy.receiveAnswer.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, _answer);
        // TODO: bridge the message using the preferred type of bridge.
        // a placeholder:
        // _bridge.sendMessage(homeProxy, data);
    }
}