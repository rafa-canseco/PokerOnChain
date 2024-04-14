// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Ownable} from "./Ownable.sol";
import {WrappingERC20} from "./Token.sol";
import {FHE, euint32, inEuint32, ebool, euint8} from "@fhenixprotocol/contracts/FHE.sol";
import {Evaluator7} from "./Evaluator7.sol";
import {RandomMock} from "./RandomMock.sol";

contract Poker is Ownable {
    enum TableState {
        Active,
        Inactive,
        Showdown
    }
    enum PlayerAction {
        Call,
        Raise,
        Check,
        Fold
    }

    event NewTableCreated(uint tableId, Table table);
    event NewBuyIn(uint tableId, address player);
    event RoundOver(uint tableId, uint round);
    event CommunityCardsDealt(uint tableId, uint roundId, uint8[] cards);
    event TableShowdown(uint tableId);

    struct Table {
        TableState state;
        uint totalHands; // Total hands played so far
        uint currentRound; // Index of the current round
        uint buyInAmount;
        uint maxPlayers;
        address[] players;
        euint32 pot;
        uint bigBlind;
        WrappingERC20 token; // The token to be used for betting at the table
    }
    struct Round {
        bool state; // State of the round, whether it is active or not
        uint turn; // An index on the players array, the player who has the current turn
        address[] players; // Players still in the round who have not folded
        euint32 highestChip; // The current highest chip to be called in the round, now encrypted
        euint32[] chips; // The amount of chips each player has put in the round, now encrypted
    }
    struct PlayerCardHashes {
        bytes32 card1Hash;
        bytes32 card2Hash;
    }
    struct PlayerCards {
        uint8 card1;
        uint8 card2;
    }

    address public immutable EVALUATOR7;
    uint public totalTables;
    mapping(uint => Table) public tables;
    mapping(address => mapping(uint => euint32)) public chips;
    mapping(address => mapping(uint => mapping(uint => PlayerCardHashes)))
        public playerHashes;
    mapping(uint => mapping(uint => Round)) public rounds;
    mapping(uint => uint8[]) public communityCards;
    mapping(address => bytes32) public playerPublicKeys;
    euint32 internal CONST_0_ENCRYPTED;

    constructor(address _evaluator7, address _wrappingERC20Token) {
        EVALUATOR7 = _evaluator7;
        CONST_0_ENCRYPTED = FHE.asEuint32(0);
    }

    function withdrawChips(
        inEuint32 calldata _encryptedAmount,
        uint _tableId
    ) external {
        euint32 encryptedAmount = FHE.asEuint32(_encryptedAmount.data);

        ebool hasEnoughChips = FHE.gte(
            chips[msg.sender][_tableId],
            encryptedAmount
        );
        FHE.req(hasEnoughChips);

        chips[msg.sender][_tableId] = FHE.sub(
            chips[msg.sender][_tableId],
            encryptedAmount
        );

        tables[_tableId].token.transferEncrypted(msg.sender, _encryptedAmount);
    }


    function createTable(
        uint _buyInAmount,
        uint _maxPlayers,
        uint _bigBlind,
        address _token
    ) external {
        address[] memory empty;

        tables[totalTables] = Table({
            state: TableState.Inactive,
            totalHands: 0,
            currentRound: 0,
            buyInAmount: _buyInAmount,
            maxPlayers: _maxPlayers,
            players: empty,
            pot: CONST_0_ENCRYPTED,
            bigBlind: _bigBlind,
            token: WrappingERC20(_token)
        });

        emit NewTableCreated(totalTables, tables[totalTables]);

        totalTables += 1;
    }

    function buyIn(uint _tableId, inEuint32 calldata _encryptedAmount) public {
        Table storage table = tables[_tableId];

        require(table.players.length < table.maxPlayers, "Table full");

        euint32 encryptedMinAmount = FHE.asEuint32(table.buyInAmount);

        euint32 encryptedAmount = FHE.asEuint32(_encryptedAmount.data);

        ebool isAmountValid = FHE.gte(encryptedAmount, encryptedMinAmount);

        FHE.req(isAmountValid);

        bytes memory encryptedAmountBytes = abi.encodePacked(encryptedAmount);
        inEuint32 memory encryptedAmountStruct = inEuint32({
            data: encryptedAmountBytes
        });

        table.token.mintEncrypted(encryptedAmountStruct);

        table.token.transferEncrypted(address(this), _encryptedAmount);

        chips[msg.sender][_tableId] = FHE.add(
            chips[msg.sender][_tableId],
            encryptedAmount
        );

        table.players.push(msg.sender);

        // Emit the event. The amount is not included to maintain privacy.
        emit NewBuyIn(_tableId, msg.sender);
    }

    function setPublicKey(bytes32 _publicKey) external {
        require(_publicKey != bytes32(0), "Invalid public key");
        playerPublicKeys[msg.sender] = _publicKey;
    }

    function dealCards(
        uint _tableId,
        bytes32[] calldata publicKeys
    ) external onlyOwner {
        Table storage table = tables[_tableId];
        uint n = table.players.length;
        require(table.state == TableState.Inactive, "Game already in progress");
        require(publicKeys.length == n, "Public keys length mismatch");
        require(n > 1, "Not enough players");

        PlayerCardHashes[] memory cardHashesArray = new PlayerCardHashes[](n); // Define the array to store the card hashes
        for (uint i = 0; i < n; i++) {
            euint8 randomCard1 = RandomMock.getFakeRandomU8();
            euint8 randomCard2 = RandomMock.getFakeRandomU8();

            bytes memory encryptedCard1 = FHE.sealoutput(
                randomCard1,
                publicKeys[i]
            );
            bytes memory encryptedCard2 = FHE.sealoutput(
                randomCard2,
                publicKeys[i]
            );
            PlayerCardHashes memory cardHashes = PlayerCardHashes({
                card1Hash: bytes32(encryptedCard1),
                card2Hash: bytes32(encryptedCard2)
            });
            playerHashes[table.players[i]][_tableId][
                table.totalHands
            ] = cardHashes;
            cardHashesArray[i] = cardHashes;
        }

        table.state = TableState.Active;

        Round storage round = rounds[_tableId][0];
        round.state = true;
        round.players = table.players;
        round.highestChip = FHE.asEuint32(table.bigBlind);

        for (uint i = 0; i < n; i++) {
            if (i == (n - 1)) {
                round.chips[i] = FHE.asEuint32(table.bigBlind / 2);
                chips[round.players[i]][_tableId] = FHE.sub(
                    chips[round.players[i]][_tableId],
                    round.chips[i]
                );
            } else if (i == (n - 2)) {
                round.chips[i] = FHE.asEuint32(table.bigBlind);
                chips[round.players[i]][_tableId] = FHE.sub(
                    chips[round.players[i]][_tableId],
                    round.chips[i]
                );
            }
        }

        table.pot = FHE.add(
            FHE.add(table.pot, round.chips[n - 2]),
            round.chips[n - 1]
        );
    }

    function playHand(
        uint _tableId,
        PlayerAction _action,
        inEuint32 calldata _encryptedRaiseAmount
    ) external {
        Table storage table = tables[_tableId];
        require(table.state == TableState.Active, "No active round");

        Round storage round = rounds[_tableId][table.currentRound];
        require(round.players[round.turn] == msg.sender, "Not your turn");

        if (_action == PlayerAction.Call) {
            ebool isCallAmountValid = FHE.gte(
                round.chips[round.turn],
                round.highestChip
            );
            FHE.req(isCallAmountValid);

            // No need to deduct chips as the player has already matched the highest bet
        } else if (_action == PlayerAction.Check) {
            // You can only check if no one has bet in this round
            for (uint i = 0; i < round.players.length; i++) {
                ebool hasPlayerBet = FHE.gt(round.chips[i], FHE.asEuint32(0));
                FHE.req(hasPlayerBet);
            }
        } else if (_action == PlayerAction.Raise) {
            // In case of a raise
            euint32 encryptedRaiseAmount = FHE.asEuint32(
                _encryptedRaiseAmount.data
            );
            ebool isRaiseEnough = FHE.gt(
                encryptedRaiseAmount,
                round.highestChip
            );
            FHE.req(isRaiseEnough);

            // Deduct the encrypted chips from the player's account and update the pot
            chips[msg.sender][_tableId] = FHE.sub(
                chips[msg.sender][_tableId],
                encryptedRaiseAmount
            );
            table.pot = FHE.add(table.pot, encryptedRaiseAmount);
            round.highestChip = FHE.max(
                round.highestChip,
                encryptedRaiseAmount
            );
        } else if (_action == PlayerAction.Fold) {
            // In case of a fold
            _removePlayerAndChips(round, round.turn, _tableId);
        }

        _finishRound(_tableId, table);
    }

    function _removePlayerAndChips(
        Round storage round,
        uint playerIndex,
        uint _tableId // Add the table identifier as a parameter
    ) internal {
        Table storage table = tables[_tableId]; // Access the corresponding table
        // Remove the player's chips from the table's pot, not from the round
        table.pot = FHE.sub(table.pot, round.chips[playerIndex]);
        // Remove the player from the round
        _remove(playerIndex, round.players);
        // Remove the player's chips from the round
        _remove(playerIndex, round.chips);
    }

    function showdown(
        uint _tableId,
        uint[] memory _keys,
        PlayerCards[] memory _cards
    ) external onlyOwner {
        Table storage table = tables[_tableId];
        require(
            table.state == TableState.Showdown,
            "Table is not in showdown state"
        );

        Round storage round = rounds[_tableId][table.currentRound];
        uint n = round.players.length;
        require(
            _keys.length == n && _cards.length == n,
            "Keys and cards length mismatch"
        );

        // Verify the players' cards with the stored hashes
        for (uint i = 0; i < n; i++) {
            bytes32 card1Hash = keccak256(
                abi.encodePacked(_keys[i], _cards[i].card1)
            );
            bytes32 card2Hash = keccak256(
                abi.encodePacked(_keys[i], _cards[i].card2)
            );

            PlayerCardHashes storage storedHashes = playerHashes[
                round.players[i]
            ][_tableId][table.totalHands];
            require(
                storedHashes.card1Hash == card1Hash &&
                    storedHashes.card2Hash == card2Hash,
                "Card verification failed"
            );
        }

        // Choose the winner
        address winner;
        uint8 bestRank = 255; // Start with the worst possible rank

        for (uint j = 0; j < n; j++) {
            uint8[] memory cCards = communityCards[_tableId];
            uint8 rank = Evaluator7(EVALUATOR7).handRank(
                cCards[0],
                cCards[1],
                cCards[2],
                cCards[3],
                cCards[4],
                _cards[j].card1,
                _cards[j].card2
            );

            if (rank < bestRank) {
                bestRank = rank;
                winner = round.players[j];
            }
        }

        // Add to the winner's balance
        require(winner != address(0), "Winner is zero address");
        chips[winner][_tableId] = FHE.add(chips[winner][_tableId], table.pot);

        // Reset the table for the next hand
        _reInitiateTable(table, _tableId);
    }

    /// @dev Method called by the offchain node to update the community cards for the next round
    /// @param _roundId The round for which the cards are being dealt (1=>Flop, 2=>Turn, 3=>River)
    /// @param _cards Code of each card(s), (as per the PokerHandUtils Library)
    function dealCommunityCards(
        uint _tableId,
        uint _roundId,
        uint8[] memory _cards
    ) external onlyOwner {
        for (uint i = 0; i < _cards.length; i++) {
            communityCards[_tableId].push(_cards[i]);
        }
        emit CommunityCardsDealt(_tableId, _roundId, _cards);
    }

    function _finishRound(uint _tableId, Table storage _table) internal {
        Round storage _round = rounds[_tableId][_table.currentRound];
        uint n = _round.players.length;
        bool allChipsEqual = _allElementsEqual(_round.chips);

        if (n == 1) {
            // Only one player left, so they win the pot
            chips[_round.players[0]][_tableId] = FHE.add(
                chips[_round.players[0]][_tableId],
                _table.pot
            );
            _reInitiateTable(_table, _tableId);
        } else if (allChipsEqual) {
            // If all chips are equal, move to the next round or showdown
            if (_table.currentRound == 3) {
                // Last round, move to showdown
                _table.state = TableState.Showdown;
                emit TableShowdown(_tableId);
            } else {
                // Move to the next round
                if (_round.turn == n - 1) {
                    emit RoundOver(_tableId, _table.currentRound);
                    _table.currentRound += 1;
                    euint32[] memory _chips = new euint32[](n); // Use euint32 for encrypted values
                    for (uint i = 0; i < n; i++) {
                        _chips[i] = FHE.asEuint32(0); // Initialize with encrypted zero
                    }
                    rounds[_tableId][_table.currentRound] = Round({
                        state: true,
                        turn: 0,
                        players: _round.players,
                        highestChip: FHE.asEuint32(0), // Initialize with encrypted zero
                        chips: _chips
                    });
                }
            }
        } else {
            // If someone has raised the bet, update the turn
            _round.turn = _updateTurn(_round.turn, n);
        }
    }

    // Updates the turn to the next player
    function _updateTurn(
        uint _currentTurn,
        uint _totalLength
    ) internal pure returns (uint) {
        if (_currentTurn == _totalLength - 1) {
            return 0;
        }
        return _currentTurn + 1;
    }

    function _reInitiateTable(Table storage _table, uint _tableId) internal {
        _table.state = TableState.Inactive;
        _table.totalHands += 1;
        _table.currentRound = 0;
        _table.pot = CONST_0_ENCRYPTED;
        delete communityCards[_tableId]; // Delete the community cards of the previous round

        // Initiate the first round
        Round storage round = rounds[_tableId][0];
        round.state = true;
        round.players = _table.players;
        round.highestChip = FHE.asEuint32(_table.bigBlind);
    }
function _allElementsEqual(euint32[] storage arr) internal view returns (bool) {
    if (arr.length == 0) {
        return true;
    }
    uint32 x = FHE.decrypt(arr[0]);
    for (uint i = 1; i < arr.length; i++) {
        if (FHE.decrypt(arr[i]) != x) {
            return false;
        }
    }
    return true;
}

    // Add this new overloaded function to handle euint32[] storage
    function _remove(uint index, euint32[] storage arr) internal {
        require(index < arr.length, "Index out of bounds");
        arr[index] = arr[arr.length - 1];
        arr.pop();
    }
    // Add this new overloaded function to handle address[] storage
function _remove(uint index, address[] storage arr) internal {
    require(index < arr.length, "Index out of bounds");
    arr[index] = arr[arr.length - 1];
    arr.pop();
}
}
