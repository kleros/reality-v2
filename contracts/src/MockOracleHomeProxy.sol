pragma solidity 0.8.24;

import {IForeignProxy} from "./MockOracleForeignProxy.sol";

interface IHomeProxy {
    function receiveAnswer(bytes32 _questionID, bytes32 _answer) external;
}

// Proxy on a chain with a dapp asking a question. (e.g Mainnet)
// Home proxy - relays the question, receives the answer and exposes it. Also relays the chain
// Note that per each supported chain there is one ForeignProxy-HomeProxy pair. And each pair can support multiple bridge types.
// At this stage bridging mechanism is unfinished and simplified.
contract MockOracleHomeProxy is IHomeProxy {
    enum Status {
        None,
        Created,
        Answered
    }

    struct Question {
        Status status;
        bytes32 answer;
    }

    address foreignProxy;
    mapping(bytes32 questionID => Question) public questions;
    mapping(address bridge => bool) public bridgeWhitelist;

    constructor(address _foreignProxy, address[] memory _bridges) {
        foreignProxy = _foreignProxy;
        for (uint256 i = 0; i < _bridges.length; i++) {
            bridgeWhitelist[_bridges[i]] = true;
        }
    }

    // TODO: add separate functions for each bridge type?
    // TODO: allow to replay the tx using a different bridge?
    // TODO: let the foreign proxy notify home proxy that the tx was received or failed?

    function askQuestion(
        string memory _questionData,
        uint256 _timeout,
        uint256 _openingTime,
        uint256 _minBond,
        address _bridge
    ) external payable { 
        if(!bridgeWhitelist[_bridge]) revert(); 
        // TODO: define what constitutes question ID.
        bytes32 questionID = keccak256(abi.encodePacked(address(this), _questionData, msg.sender, block.timestamp, block.chainid));
        Question storage question = questions[questionID];
        if(question.status != Status.None) revert();
        question.status = Status.Created;
        bytes4 methodSelector = IForeignProxy.receiveQuestion.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, block.chainid, questionID, _questionData, _timeout, _openingTime, _minBond);
        // TODO: bridge the message along with the msg.value using the preferred type of bridge.
        // a placeholder:
        // _bridge.sendMessage(foreignProxy, msg.value, data);
    }

    function receiveAnswer(bytes32 _questionID, bytes32 _answer) external {
        if(!bridgeWhitelist[msg.sender]) revert(); 
        // TODO: check that the sender on foreign chain is foreign proxy.
        Question storage question = questions[_questionID];
        if(question.status != Status.Created) revert();
        question.status = Status.Answered;
        question.answer = _answer;
        // TODO: expose/relay the answer to the querying dapp
    }   
}