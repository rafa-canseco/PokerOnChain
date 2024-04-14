// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {inEuint8, euint8, inEuint16, euint16, FHE} from "@fhenixprotocol/contracts/FHE.sol";
import "@fhenixprotocol/contracts/access/Permissioned.sol";

contract Poker is Permissioned {
  // players
  address[] public players;
  // current stack
  mapping(address => uint256) public currentStack;
  // player cards
  mapping( address => uint256) public playerCards;
  // encrypted cards
  euint8[] public cards;
  // open cards
  uint8[] public tableCards;
  bool[] public tableCardsRevealed;
  // players still in the game
  mapping(address => bool) public stillPlaying;
  // current round
  uint8 public currentRound;
  // player whose turn it is
  address public currentPlayer;
  // current bet
  uint256 public currentBet;
  // pot
  uint256 public pot;

  constructor() {
    currentPlayer = address(0);
    currentRound = 0;
    currentBet = 0;
    pot = 0;
  }

  function joinGame() public payable {
    require(players.length < 5, "Game is full");
    require(!isPlayer(msg.sender), "You are already in the game");
    require(
      msg.value == 0.0000001 ether,
      "You need to pay 1 ether to join the game"
    );

    players.push(msg.sender);
    currentStack[msg.sender] = msg.value * 10000;
    stillPlaying[msg.sender] = true;
  }

  function startGame() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(players.length > 1, "Not enough players to start the game");
    require(cards.length == 0, "Game already started");
    require(
      playerIndex(msg.sender) == 0,
      "Only the first player can start the game"
    );

    deal();
    currentPlayer = players[0];
  }

  function bet(uint256 amount) public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(stillPlaying[msg.sender], "You are not in the game");
    require(
      amount <= currentStack[msg.sender],
      "You don't have enough money to bet"
    );
    require(currentPlayer == msg.sender, "It's not your turn");
    require(amount >= currentBet, "You need to bet at least the current bet");
    require(currentRound < 4, "Game is over");

    currentStack[msg.sender] -= amount;
    pot += amount;
    currentBet = amount;

    uint8 index = (playerIndex(msg.sender) + 1) % uint8(players.length);
    if (index == 0) {
      currentBet = 0;
      if (currentRound == 0) {
        revealOnTable(0, 3);
      } else if (currentRound == 1) {
        revealOnTable(3, 4);
      } else if (currentRound == 2) {
        revealOnTable(4, 5);
      } else if (currentRound == 3) {
        address[] memory tmp = determineWinners();
        distributePot(tmp);
      }
      currentRound++;
    }
    currentPlayer = players[index];
  }

  function fold() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(stillPlaying[msg.sender], "You are not in the game");
    require(currentPlayer == msg.sender, "It's not your turn");
    require(currentRound < 4, "Game is over");

    stillPlaying[msg.sender] = false;

    uint8 index = (playerIndex(msg.sender) + 1) % uint8(players.length);
    if (index == 0) {
      currentBet = 0;
      if (currentRound == 0) {
        revealOnTable(0, 3);
      } else if (currentRound == 1) {
        revealOnTable(3, 4);
      } else if (currentRound == 2) {
        revealOnTable(4, 5);
      } else if (currentRound == 3) {
        address[] memory tmp = determineWinners();
        distributePot(tmp);
      }
      currentRound++;
    }
    currentPlayer = players[index];
  }

  function deal() internal {
    require(players.length > 1, "Not enough players to start the game");
    require(cards.length == 0, "Game already started");

    // create a new deck of cards
    cards = new euint8[](players.length * 2 + 5);
    tableCards = new uint8[](players.length * 2 + 5);
    tableCardsRevealed = new bool[](players.length * 2 + 5);

     for (uint8 i = 0; i < players.length; i++) {
    playerCards[players[i]] = i * 2;
  }

    for (uint8 i = 0; i < cards.length; ) {
      euint8 color = RandomMock.getFakeRandomU8();
      euint8 value = RandomMock.getFakeRandomU8();
      euint8 card = FHE.or(
        FHE.and(color, FHE.asEuint8(0x30)),
        FHE.and(value, FHE.asEuint8(0xf))
      );

      // sanity check value below 13
      card = FHE.select(
        FHE.lt(FHE.and(card, FHE.asEuint8(0xf)), FHE.asEuint8(13)),
        card,
        FHE.asEuint8(0xff)
      );
      // check if card exists, else "continue"
      for (uint8 j = 0; j < i; j++) {
        card = FHE.select(FHE.eq(cards[j], card), card, FHE.asEuint8(0xff));
      }

      cards[i] = card;
      euint8 e_i = FHE.select(
        FHE.ne(card, FHE.asEuint8(0xff)),
        FHE.asEuint8(i + 1),
        FHE.asEuint8(i)
      );
      i = FHE.decrypt(e_i);

      if (i >= (players.length * 2 + 5)) break;
    }
  }

  function revealOwnCards(
    Permission calldata perm
  ) public view onlySender(perm) returns (bytes memory) {
    require(isPlayer(msg.sender), "You are not in the game");
    require(cards.length > 0, "No cards to reveal");

    uint8 index = playerIndex(msg.sender);
    require(index < players.length, "Player not found");
    require(index < (cards.length - 5) / 2, "Player not assigned cards");

    euint16 ret = FHE.or(
      FHE.asEuint16(cards[2 * index]),
      FHE.shl(FHE.asEuint16(cards[2 * (index + 1)]), FHE.asEuint16(8))
    );
    return FHE.sealoutput(ret, perm.publicKey);
    // check which cards are assigned
    // return permissioned player cards
  }

  function revealOnTable(uint8 start, uint8 end) private {
    require(cards.length > 0, "No cards to reveal");
    require(start < end, "Invalid range");
    require(end <= tableCards.length, "Invalid range");

    uint256 tableCardIndex = players.length * 2;
    for (uint8 i = start; i < end; i++) {
      uint8 tmp = FHE.decrypt(cards[tableCardIndex + i]);
      tableCards[tableCardIndex + i] = tmp;
      tableCardsRevealed[tableCardIndex + i] = true;
    }
  }

  // this function implements our poker ruleset
  // call after all cards are revealed
  // possible hands:
  // - high card
  // - pair
  // - two pair
  // - three of a kind
  // - flush
  // - four of a kind
  // TODO: implement high card winner
  function determineWinners() internal returns (address[] memory) {
    require(cards.length > 0, "No cards have been distributed");
    require(tableCards.length > 0, "No table cards to reveal");

    // check hands of all players and track highest hand(s)
    // if multiple players have the same hand, check the highest card
    // if multiple players have the same hand and highest card, split the pot
    // if no players have a hand, split the pot
    for (uint8 i = 0; i < players.length; i++) {

      if (!stillPlaying[players[i]]) continue;
        uint256 playerCardIndex = playerCards[players[i]];
        tableCards[2 * i] = FHE.decrypt(cards[playerCardIndex]);
        tableCards[2 * i + 1] = FHE.decrypt(cards[playerCardIndex + 1]);
        tableCardsRevealed[2 * i] = true;
        tableCardsRevealed[2 * i + 1] = true;
        }


    uint8 highestHand = 0;
    uint8 highestHandCount = 0;
    uint8[] memory highestHandPlayers = new uint8[](players.length);

    for (uint8 i = 0; i < players.length; i++) {
      if (!stillPlaying[players[i]]) continue;
      uint8 hand = determineHand(i);
      if (hand > highestHand) {
        delete highestHandPlayers;
        highestHand = hand;
        highestHandPlayers[highestHandCount] = i;
        highestHandCount++;
      }
      if (hand == highestHand) {
        highestHandPlayers[highestHandCount] = i;
        highestHandCount++;
      }
    }

    address[] memory winners = new address[](highestHandCount);
    for (uint8 i = 0; i < highestHandCount; i++) {
      winners[i] = players[highestHandPlayers[i]];
    }

    return winners;
  }

  function distributePot(address[] memory winners) internal {
    // distribute pot to winners
    for (uint8 i = 0; i < winners.length; i++) {
      currentStack[winners[i]] += pot / winners.length;
    }
    pot = 0;
  }

  // determine hand for a single player
  function determineHand(uint8 player) internal view returns (uint8) {
    // high card 0, pair 1, two pair 2, three of a kind 3, flush 4, four of a kind 5
    // start from highest possible hand and work down
    // four of a kind
    uint8 multiple = hasMultipleOfAKind(player);
    if (multiple == 4) return 5;
    else if (hasFlush(player)) return 4;
    else if (multiple == 3) return 3;
    else if (hasTwoPair(player)) return 2;
    else if (multiple == 2) return 1;
    return 0;
  }

  // check if player has multiple of a kind, return multiplicity
  function hasMultipleOfAKind(uint8 player) internal view returns (uint8) {
    uint8[] memory values = new uint8[](13);
    for (uint8 i = 0; i < 13; i++) values[i] = 0;

    // only check revealed cards
    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
      relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    for (uint8 i = 0; i < 7; i++) {
      uint8 value = getValue(relevantCards[i]);
      values[value]++;
    }

    // find highest of a kind
    uint8 highest = 0;
    for (uint8 i = 0; i < 13; i++) {
      if (values[i] > highest) highest = values[i];
    }

    return highest;
  }

  // check if player has a flush
  function hasFlush(uint8 player) internal view returns (bool) {
    uint8[] memory colors = new uint8[](4);
    for (uint8 i = 0; i < 4; i++) colors[i] = 0;

    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
      relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    for (uint8 i = 0; i < 7; i++) {
      uint8 color = getColor(relevantCards[i]);
      colors[color]++;
    }

    for (uint8 i = 0; i < 4; i++) {
      if (colors[i] > 3) return true;
    }

    return false;
  }

  // check if player has a two-pair
  function hasTwoPair(uint8 player) internal view returns (bool) {
    uint8[] memory values = new uint8[](13);
    for (uint8 i = 0; i < 13; i++) values[i] = 0;

    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
      relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    for (uint8 i = 0; i < 7; i++) {
      uint8 value = getValue(relevantCards[i]);
      values[value]++;
    }

    uint8 pairs = 0;
    for (uint8 i = 0; i < 13; i++) {
      if (values[i] > 1) pairs++;
    }

    return pairs > 1;
  }

  function getColor(uint8 card) internal pure returns (uint8) {
    return card & 0x30;
  }

  function getValue(uint8 card) internal pure returns (uint8) {
    return card & 0xf;
  }

  function isPlayer(address player) public view returns (bool) {
    for (uint8 i = 0; i < players.length; i++) {
      if (players[i] == player) {
        return true;
      }
    }
    return false;
  }

  function playerIndex(address player) public view returns (uint8) {
    for (uint8 i = 0; i < players.length; i++) {
      if (players[i] == player) {
        return i;
      }
    }
    return 0xff;
  }

  function gameState()
    external
    view
    returns (
      uint256 playerCount,
      uint256 playerStack,
      uint8 round,
      address playerAddress,
      uint256 playerBet,
      uint256 cardCount,
      uint8[] memory cardsOnTable,
      bool[] memory cardsRevealed,
      address[] memory playerAddresses
    )
  {
    return (
      players.length,
      currentStack[msg.sender],
      currentRound,
      currentPlayer,
      currentBet,
      tableCards.length,
      tableCards,
      tableCardsRevealed,
      players
    );
  }
}

library RandomMock {
  function getFakeRandom() internal view returns (uint256) {
    uint blockNumber = block.number;
    uint256 blockHash = uint256(blockhash(blockNumber));

    return blockHash;
  }

  function getFakeRandomU8() internal view returns (euint8) {
    uint8 blockHash = uint8(getFakeRandom());
    return FHE.asEuint8(blockHash);
  }
}
