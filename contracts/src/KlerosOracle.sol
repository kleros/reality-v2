// SPDX-License-Identifier: MIT

/**
 *  @authors: [@unknownunknown1]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity 0.8.24;

import {IArbitrableV2, IArbitratorV2} from "@kleros/kleros-v2-contracts/arbitration/interfaces/IArbitrableV2.sol";
import {IForeignProxy} from "./MockOracleForeignProxy.sol";

// A preliminary draft of the oracle contract, to estimate feasibility.
contract KlerosOracle is IArbitrableV2 {

    uint256 private constant NUMBER_OF_RULING_OPTIONS = type(uint256).max;

    enum Status {
        None, // The question hasn't been requested arbitration yet.
        Created, // Question is created.
        Answered, // Question is answered.
        Disputed, // The question has been requested arbitration.
        Ruled, // The question has been ruled by arbitrator.
        Reported // The answer of the question has been reported to homechain.
    }

    struct Question {
        Status status; // The current status of the question.
        uint256 disputeID; // The ID of the dispute raised in the arbitrator contract.
        uint256 chainID; // Corresponding chain ID of the requesting dapp.
        uint256 timeout; // Time allotted to answer the question.
        uint256 openingTime; // Time after which the question can be answered.
        string questionData; // Contents of the question (e.g. text, rulings, etc).
        bytes32 answer; // Answer given to the question. TODO: unify the type somehow.
        address payable answerer; // Address that answered the question
        address payable disputer; // Address that requested arbitration
        uint256 bond; // Bond paid by answerer.
        uint256 reward; // Reward proposed by requester.
        uint256 minBond; // Min bond to answer.
        uint256 finalizationTime; // Time when the question becomes finalized.
    }

    IArbitratorV2 public arbitrator; // The arbitrator trusted to solve disputes for this request.
    bytes public arbitratorExtraData; // The extra data for the trusted arbitrator of this request.
    address public governor;

    mapping(bytes32 questionID => Question) public questions;
    mapping(uint256 chainID => mapping (address proxy => bool whitelisted)) public proxyWhitelist;
    mapping(uint256 disputeID => bytes32 questionID) public disputeIDToQuestionID;

    modifier onlyGovernor() {
        if (governor != msg.sender) revert();
        _;
    }

    constructor(
        IArbitratorV2 _arbitrator,
        bytes memory _arbitratorExtraData,
        address _governor
    ) {
        governor = msg.sender;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    function manageWhitelist(uint256 _chainID, address _proxy, bool _enable) external onlyGovernor() {
        // TODO: When disable whitelist check that no active questions
        proxyWhitelist[_chainID][_proxy] = _enable;

    }

    // Note that question-answer logic and tokenomics are greatly simplified.
    function askQuestion(
        uint256 _chainID,
        bytes32 _questionID,
        string memory _questionData,
        uint256 _timeout,
        uint256 _openingTime,
        uint256 _minBond
    )
        public
        payable

    {   
        if (!proxyWhitelist[_chainID][msg.sender]) revert();
        // TODO: templates and question types.
    
        Question storage question = questions[_questionID];
        if(question.status != Status.None) revert();
        question.openingTime = _openingTime;
        question.timeout = _timeout;
        question.questionData = _questionData;
        question.chainID = _chainID;
        question.reward = msg.value;
        question.minBond = _minBond;
        question.status = Status.Created;
    }

    // Proposed answer can be challenged later until timeout.
    function proposeAnswer(
        bytes32 _questionID,
        bytes32 _answer
    ) external payable {
        Question storage question = questions[_questionID];
        if(question.status != Status.Created) revert();
        if(msg.value < question.minBond) revert();
        if(block.timestamp < question.openingTime) revert();

        question.answer = _answer;
        question.answerer = payable(msg.sender);
        question.status = Status.Answered;
        question.bond = msg.value;
        question.finalizationTime = block.timestamp + question.timeout;
    }

    function requestArbitration(bytes32 _questionID) external payable returns (uint256 disputeID) {        
        Question storage question = questions[_questionID];
        if(block.timestamp >= question.finalizationTime) revert();
        if (question.status != Status.Answered) revert();
        if (msg.value < arbitrator.arbitrationCost(arbitratorExtraData)) revert();

        // Notify Kleros Court
        // Arbitration cost surplus will be used to get additional votes.
        disputeID = arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, arbitratorExtraData);
        disputeIDToQuestionID[disputeID] = _questionID;

        question.disputer = payable(msg.sender);
        question.status = Status.Disputed;
        question.disputeID = disputeID;
    }

    /// @dev Receives ruling from Kleros and enforces it.
    /// @param _disputeID ID of Kleros dispute.
    /// @param _ruling Ruling that is given by Kleros.
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        bytes32 questionID = disputeIDToQuestionID[_disputeID];
        Question storage question = questions[questionID];

        if (IArbitratorV2(msg.sender) != arbitrator) revert();
        if (question.status != Status.Disputed) revert();

        question.status = Status.Ruled;

        uint256 reward = question.reward;
        uint256 bond = question.bond;
        question.reward = 0;
        question.bond = 0;
        // Compare the existing answer from the answerer with the ruling
        if (question.answer == bytes32(_ruling)) {
            // Send reward to initial answerer and reimburse his bond
            question.answerer.send(reward + bond);
        } else {
            // Send reward and bond to the disputer
            question.disputer.send(reward + bond);
            
            // Replace the answer with the ruling
            question.answer = bytes32(_ruling);
        }
        // TODO: handle "answered too soon"

        emit Ruling(IArbitratorV2(msg.sender), _disputeID, _ruling);
    }

    // Choose the proxy and the bridge, and allow to replay the tx to use faster/slower bridges to your liking
    // Note that it's a job of the homeproxy to handle idempotency, and bridge address should be vetted by the proxy itself
    function reportAnswer(bytes32 _questionID, address _proxy, address _bridge) external {
        Question storage question = questions[_questionID];
        // TODO: store the foreign proxy address when the question is created and use that address instead of _proxy parameter.
        if (!proxyWhitelist[question.chainID][_proxy]) revert();
        
        require(question.status == Status.Ruled || question.status == Status.Answered || question.status == Status.Reported);
        if (question.status == Status.Answered) {
            require(block.timestamp > question.finalizationTime); // Time to challenge should pass
        }        

        question.status = Status.Reported;

        // Home proxy should be paired with the selected proxy
        IForeignProxy(_proxy).reportAnswer(_questionID, question.answer, _bridge);
    }

    // TODO: options when the requester is one the same chain.
}
