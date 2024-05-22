// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {inEuint8, euint8, inEuint16, euint16, FHE} from "@fhenixprotocol/contracts/FHE.sol";
import "@fhenixprotocol/contracts/access/Permissioned.sol";

contract Poker is Permissioned {
  /////////////////
  // Variables////
  ////////////////

  // Players
  address[] public players;
  // Current stack
  mapping(address => uint256) public currentStack;
  // Player cards
  mapping(address => uint256) public playerCards;
  // Encrypted cards
  euint8[] public cards;
  // Open cards
  uint8[] public tableCards;
  bool[] public tableCardsRevealed;
  // Players still in the game
  mapping(address => bool) public stillPlaying;
  // Current round
  uint8 public currentRound;
  // Player whose turn it is
  address public currentPlayer;
  // Current bet
  uint256 public currentBet;
  // Pot
  uint256 public pot;
  //Position of the dealer
  uint8 public dealerIndex;
  // Game ended
  bool public gameEnded;
  // Blinds
  uint256 public smallBlind;
  unit256 public bigBlind;
  // Action timeout if players dont do anything
  uint256 public constant ACTION_TIMEOUT = 1 minutes;
  mapping(address => uint256) public lastActionTimestamp;
  //////////////
  // Events/////
  /////////////
  event AutoCheck(address indexed player);
  event AutoFold(address indexed player);
  event PlayerJoined(address indexed player);
  event PlayerLeft(address indexed player);
  event GameStarted();
  event RoundStarted(uint256 roundNumber);
  event RoundEnded(uint256 roundNumber);
  event PlayerBet(address indexed player, uint256 amount);
  event PlayerCalled(address indexed player);
  event PlayerChecked(address indexed player);
  event PlayerFolded(address indexed player);
  event PotDistributed(address indexed winner, uint256 amount);
  event GameEnded();

  
  // Constructor to initialize the game state
  constructor() {
    currentPlayer = address(0); // No current player at the start
    currentRound = 0; // Initial round is 0
    currentBet = 0; // No bets at the start
    pot = 0; // Pot starts at 0
    gameEnded = false; // Game has not ended at the start
  }

  // Function to allow a player to join the game
  function joinGame() public payable {
    require(players.length < 5, "Game is full"); // Maximum of 5 players allowed
    require(!isPlayer(msg.sender), "You are already in the game"); // Player should not already be in the game
    require(
      msg.value == 0.0000001 ether,
      "You need to pay 1 ether to join the game"
    ); // Player must pay 1 ether to join

    players.push(msg.sender); // Add player to the list
    currentStack[msg.sender] = msg.value * 10000; // Initialize player's stack
    stillPlaying[msg.sender] = true; // Mark player as still playing

    emit PlayerJoined(msg.sender); // Emit event for player joining
  }

  // Function to set the values of small and big blinds
  function setBlindValues(uint256 _smallBlind, uint256 _bigBlind) public onlyOwner {
    smallBlind = _smallBlind; // Set the small blind value
    bigBlind = _bigBlind; // Set the big blind value
  }

function setBlinds(uint256 smallBlind, uint256 bigBlind) internal {
    // Ensure there are at least 2 players to set blinds
    require(players.length >= 2, "Not enough players to set blinds");
    // Calculate the indices for small and big blinds
    uint8 smallBlindIndex = (dealerIndex + 1) % uint8(players.length);
    uint8 bigBlindIndex = (dealerIndex + 2) % uint8(players.length);

    // Find the next active player for small blind
    while (!stillPlaying[players[smallBlindIndex]]) {
        smallBlindIndex = (smallBlindIndex + 1) % uint8(players.length);
    }

    // Find the next active player for big blind
    while (!stillPlaying[players[bigBlindIndex]]) {
        bigBlindIndex = (bigBlindIndex + 1) % uint8(players.length);
    }

    // Handle small blind
    if (currentStack[players[smallBlindIndex]] >= smallBlind) {
        // Deduct small blind from player's stack and add to pot
        currentStack[players[smallBlindIndex]] -= smallBlind;
        pot += smallBlind;
    } else {
        // If player cannot cover small blind, go all-in
        pot += currentStack[players[smallBlindIndex]];
        currentStack[players[smallBlindIndex]] = 0;
    }

    // Handle big blind
    if (currentStack[players[bigBlindIndex]] >= bigBlind) {
        // Deduct big blind from player's stack and add to pot
        currentStack[players[bigBlindIndex]] -= bigBlind;
        pot += bigBlind;
        currentBet = bigBlind;
    } else {
        // If player cannot cover big blind, go all-in
        pot += currentStack[players[bigBlindIndex]];
        currentBet = currentStack[players[bigBlindIndex]];
        currentStack[players[bigBlindIndex]] = 0;
    }

    // Set the current player to the one after the big blind
    currentPlayer = players[(bigBlindIndex + 1) % players.length];
}

function removePlayer(address player) internal {
    // Loop through the players to find the one to remove
    for (uint256 i = 0; i < players.length; i++) {
        if (players[i] == player) {
            // Replace the player to be removed with the last player in the list
            players[i] = players[players.length - 1];
            // Remove the last player from the list
            players.pop();
            break;
        }
    }
}

function startGame() public {
    require(isPlayer(msg.sender), "You are not in the game"); // Ensure the caller is a player
    require(players.length > 1, "Not enough players to start the game"); // Ensure there are enough players
    require(cards.length == 0, "Game already started"); // Ensure the game hasn't started
    require(playerIndex(msg.sender) == 0, "Only the first player can start the game"); // Ensure the first player starts the game

    dealerIndex = 0; // Initialize the dealer
    deal(); // Deal the cards
    setBlinds(smallBlind, bigBlind); // Set the blinds
    currentPlayer = players[(dealerIndex + 3) % players.length]; // Set the current player
    emit GameStarted(); // Emit the game started event
}

function check() public {
    require(isPlayer(msg.sender), "You are not in the game"); // Ensure the caller is a player
    require(stillPlaying[msg.sender], "You are not in the game"); // Ensure the player is still playing
    require(currentPlayer == msg.sender, "It's not your turn"); // Ensure it's the player's turn
    require(currentBet == 0, "You cannot check, there is a bet"); // Ensure there is no bet to check
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout"); // Ensure the action is within the timeout

    lastActionTimestamp[msg.sender] = block.timestamp; // Update the last action timestamp

    uint8 index = (playerIndex(msg.sender) + 1) % uint8(players.length); // Calculate the next player index
    currentPlayer = players[index]; // Set the current player
    advanceTurn(); // Advance the turn
    if (playerIndex(currentPlayer) == 0) { // If it's the first player's turn
        currentBet = 0; // Reset the current bet
        if (currentRound == 0) {
            revealOnTable(0, 3); // Reveal the first three cards
        } else if (currentRound == 1) {
            revealOnTable(3, 4); // Reveal the fourth card
        } else if (currentRound == 2) {
            revealOnTable(4, 5); // Reveal the fifth card
        } else if (currentRound == 3) {
            address[] memory tmp = determineWinners(); // Determine the winners
            distributePot(tmp); // Distribute the pot
        }
        currentRound++; // Advance the round
        emit PlayerChecked(msg.sender); // Emit the player checked event
    }
}
function leaveGame() public {
    require(isPlayer(msg.sender), "You are not in the game"); // Ensure the caller is a player
    require(!stillPlaying[msg.sender], "You cannot leave while still playing a hand"); // Ensure the player is not still playing a hand

    uint256 amount = currentStack[msg.sender]; // Get the player's current stack
    currentStack[msg.sender] = 0; // Reset the player's stack
    removePlayer(msg.sender); // Remove the player from the game

    payable(msg.sender).transfer(amount); // Transfer the player's stack amount to their address

    // If the player leaving is the current player, advance to the next player
    if (currentPlayer == msg.sender) {
        advanceTurn();
    }

    // If there are not enough players to continue, end the game
    if (players.length < 2) {
        gameEnded = true;
    }
    emit PlayerLeft(msg.sender); // Emit the player left event
}

function call() public {
    require(isPlayer(msg.sender), "You are not in the game"); // Ensure the caller is a player
    require(stillPlaying[msg.sender], "You are not in the game"); // Ensure the player is still playing
    require(currentPlayer == msg.sender, "It's not your turn"); // Ensure it's the player's turn
    require(currentBet > 0, "There is no bet to call"); // Ensure there is a bet to call
    require(currentStack[msg.sender] >= currentBet, "You don't have enough money to call"); // Ensure the player has enough money to call
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout"); // Ensure the action is within the timeout
    lastActionTimestamp[msg.sender] = block.timestamp; // Update the last action timestamp

    currentStack[msg.sender] -= currentBet; // Deduct the current bet from the player's stack
    pot += currentBet; // Add the current bet to the pot

    uint8 index = (playerIndex(msg.sender) + 1) % uint8(players.length); // Calculate the next player index
    currentPlayer = players[index]; // Set the current player
    advanceTurn(); // Advance the turn
    if (playerIndex(currentPlayer) == 0) { // If it's the first player's turn
        currentBet = 0; // Reset the current bet
        if (currentRound == 0) {
            revealOnTable(0, 3); // Reveal the first three cards
        } else if (currentRound == 1) {
            revealOnTable(3, 4); // Reveal the fourth card
        } else if (currentRound == 2) {
            revealOnTable(4, 5); // Reveal the fifth card
        } else if (currentRound == 3) {
            address[] memory tmp = determineWinners(); // Determine the winners
            distributePot(tmp); // Distribute the pot
        }
        currentRound++; // Advance the round
        emit PlayerCalled(msg.sender); // Emit the player called event
    }
}

function endRound() internal {
    // Remove players with a stack of 0
    for (uint256 i = 0; i < players.length; i++) {
        if (currentStack[players[i]] == 0) {
            removePlayer(players[i]);
            i--; // Adjust the index after removing an element
        }
    }

    if (players.length < 2) {
        // End the game and award the pot to the last player with chips
        if (players.length == 1) {
            currentStack[players[0]] += pot;
            pot = 0;
        }
        // Reiniciar el juego
        gameEnded = true;
        return;
    }

    // Update the dealer index
    dealerIndex = (dealerIndex + 1) % uint8(players.length);
    currentPlayer = players[(dealerIndex + 3) % players.length];
    currentRound = 0;

    // Reset variables for the new round
    for (uint8 i = 0; i < players.length; i++) {
        stillPlaying[players[i]] = true;
    }
    currentBet = 0;
    emit RoundEnded(currentRound);
}

function bet(uint256 amount) public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(stillPlaying[msg.sender], "You are not in the game");
    require(currentPlayer == msg.sender, "It's not your turn");
    require(currentRound < 4, "Game is over");
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout");
    lastActionTimestamp[msg.sender] = block.timestamp;

    uint256 playerStack = currentStack[msg.sender];
    uint256 betAmount = amount;

    if (betAmount > playerStack) {
        betAmount = playerStack; // All-in
    }

    require(betAmount >= currentBet, "You need to bet at least the current bet");

    currentStack[msg.sender] -= betAmount;
    pot += betAmount;
    currentBet = betAmount;

    advanceTurn();
    if (playerIndex(currentPlayer) == 0) {
        currentBet = 0;
        if (currentRound == 0) {
            revealOnTable(0, 3); // Reveal the first three cards
        } else if (currentRound == 1) {
            revealOnTable(3, 4); // Reveal the fourth card
        } else if (currentRound == 2) {
            revealOnTable(4, 5); // Reveal the fifth card
        } else if (currentRound == 3) {
            address[] memory tmp = determineWinners(); // Determine the winners
            distributePot(tmp); // Distribute the pot
        }
        currentRound++;
        emit PlayerBet(msg.sender, betAmount); // Emit the player bet event
    }

    // Check if only one player has chips left
    uint256 playersWithChips = 0;
    address lastPlayerWithChips;
    for (uint256 i = 0; i < players.length; i++) {
        if (currentStack[players[i]] > 0) {
            playersWithChips++;
            lastPlayerWithChips = players[i];
        }
    }

    if (playersWithChips == 1) {
        // End the hand and award the pot to the last player with chips
        currentStack[lastPlayerWithChips] += pot;
        pot = 0;
        endRound();
        return;
    }
}

function advanceTurn() internal {
    uint8 index = (playerIndex(currentPlayer) + 1) % uint8(players.length);
    address nextPlayer = players[index];

    if (block.timestamp > lastActionTimestamp[currentPlayer] + ACTION_TIMEOUT) {
        // The current player did not act within the time limit
        if (currentBet == 0) {
            // No current bet, perform an automatic "check"
            check();
            emit AutoCheck(currentPlayer); // Emit the auto check event
        } else {
            // There is a bet, perform an automatic "fold"
            fold();
            emit AutoFold(currentPlayer); // Emit the auto fold event
        }
    }

    currentPlayer = nextPlayer;
}

event AutoCheck(address indexed player);
event AutoFold(address indexed player);
}

function fold() public {
    require(isPlayer(msg.sender), "You are not in the game"); // Ensure the sender is a player
    require(stillPlaying[msg.sender], "You are not in the game"); // Ensure the player is still in the game
    require(currentPlayer == msg.sender, "It's not your turn"); // Ensure it's the player's turn
    require(currentRound < 4, "Game is over"); // Ensure the game is not over
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout"); // Ensure the action is within the timeout period
    lastActionTimestamp[msg.sender] = block.timestamp; // Update the last action timestamp

    stillPlaying[msg.sender] = false; // Mark the player as no longer playing

    advanceTurn(); // Advance to the next player's turn
    if (playerIndex(currentPlayer) == 0) {
        currentBet = 0; // Reset the current bet
        if (currentRound == 0) {
            revealOnTable(0, 3); // Reveal the first three cards
        } else if (currentRound == 1) {
            revealOnTable(3, 4); // Reveal the fourth card
        } else if (currentRound == 2) {
            revealOnTable(4, 5); // Reveal the fifth card
        } else if (currentRound == 3) {
            address[] memory tmp = determineWinners(); // Determine the winners
            distributePot(tmp); // Distribute the pot
        }
        currentRound++; // Move to the next round
        emit PlayerFolded(msg.sender); // Emit the player folded event
    }
}

function deal() internal {
    require(players.length > 1, "Not enough players to start the game"); // Ensure there are enough players
    require(cards.length == 0, "Game already started"); // Ensure the game has not already started

    // Create a new deck of cards
    cards = new euint8[](players.length * 2 + 5);
    tableCards = new uint8[](players.length * 2 + 5);
    tableCardsRevealed = new bool[](players.length * 2 + 5);

    for (uint8 i = 0; i < players.length; i++) {
        playerCards[players[i]] = i * 2; // Assign two cards to each player
    }

    for (uint8 i = 0; i < cards.length;) {
        euint8 color = RandomMock.getFakeRandomU8(); // Get a random color
        euint8 value = RandomMock.getFakeRandomU8(); // Get a random value
        euint8 card = FHE.or(
            FHE.and(color, FHE.asEuint8(0x30)),
            FHE.and(value, FHE.asEuint8(0xf))
        );

        // Sanity check: ensure value is below 13
        card = FHE.select(
            FHE.lt(FHE.and(card, FHE.asEuint8(0xf)), FHE.asEuint8(13)),
            card,
            FHE.asEuint8(0xff)
        );

        // Check if card exists, else "continue"
        for (uint8 j = 0; j < i; j++) {
            card = FHE.select(FHE.eq(cards[j], card), card, FHE.asEuint8(0xff));
        }

        cards[i] = card; // Assign the card
        euint8 e_i = FHE.select(
            FHE.ne(card, FHE.asEuint8(0xff)),
            FHE.asEuint8(i + 1),
            FHE.asEuint8(i)
        );
        i = FHE.decrypt(e_i); // Decrypt the index

        if (i >= (players.length * 2 + 5)) break; // Break if all cards are assigned
    }
}

// Function to reveal the player's own cards
function revealOwnCards(Permission calldata perm) public view onlySender(perm) returns (bytes memory) {
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
}

// Function to distribute the pot to the winners
function distributePot(address[] memory winners) internal {
    for (uint8 i = 0; i < winners.length; i++) {
        currentStack[winners[i]] += pot / winners.length;
        emit PotDistributed(winners[i], potShare);
    }
    pot = 0;
    endRound();
}

// Function to reveal cards on the table within a specified range
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

function determineWinners() internal returns (address[] memory) {
    // Ensure that cards have been distributed
    require(cards.length > 0, "No cards have been distributed");
    // Ensure that there are table cards to reveal
    require(tableCards.length > 0, "No table cards to reveal");

    // Reveal each player's cards if they are still playing
    for (uint8 i = 0; i < players.length; i++) {
        if (!stillPlaying[players[i]]) continue;
        uint256 playerCardIndex = playerCards[players[i]];
        tableCards[2 * i] = FHE.decrypt(cards[playerCardIndex]);
        tableCards[2 * i + 1] = FHE.decrypt(cards[playerCardIndex + 1]);
        tableCardsRevealed[2 * i] = true;
        tableCardsRevealed[2 * i + 1] = true;
    }

    uint8 highestHand = 0;
    address[] memory highestHandPlayers = new address[](0);
    uint256 highestHandCount = 0;

    // Determine the highest hand among the players
    for (uint8 i = 0; i < players.length; i++) {
        if (!stillPlaying[players[i]]) continue;
        uint8 hand = determineHand(i);
        if (hand > highestHand) {
            highestHand = hand;
            highestHandPlayers = new address[](0);
            highestHandPlayers.push(players[i]);
            highestHandCount = 1;
        } else if (hand == highestHand) {
            highestHandPlayers.push(players[i]);
            highestHandCount++;
        }
    }
    // Tie-breaking logic
    if (highestHandCount > 1) {
        highestHandPlayers = breakTies(highestHandPlayers);
    }

    // Pot distribution
    uint256[] memory potentialWinnings = new uint256[](players.length);
    for (uint256 i = 0; i < players.length; i++) {
        address player = players[i];
        if (stillPlaying[player]) {
            potentialWinnings[i] = currentBet - (currentBet - currentStack[player]);
        }
    }

    // Distribute the pot considering all-ins
    uint256 remainingPot = pot;
    for (uint256 i = 0; i < highestHandPlayers.length; i++) {
        address player = highestHandPlayers[i];
        uint256 playerIndex = playerIndex(player);
        uint256 winnings = potentialWinnings[playerIndex];
        if (winnings > remainingPot) {
            winnings = remainingPot;
        }
        currentStack[player] += winnings;
        remainingPot -= winnings;
    }

    return highestHandPlayers;
}

function breakTies(address[] memory players) internal view returns (address[] memory) {
    uint8 handType = determineHand(uint8(players[0]));

    if (handType == 9 || handType == 8 || handType == 5) {
        // Royal Flush, Straight Flush, and Flush are broken by the highest card
        return compareHighCards(players, handType);
    } else if (handType == 7 || handType == 4) {
        // Four of a Kind and Straight are broken by the highest card
        return compareHighCards(players, handType);
    } else if (handType == 6) {
        // Full House is broken by the three of a kind, then by the pair
        return compareFullHouses(players);
    } else if (handType == 3 || handType == 2 || handType == 1) {
        // Three of a Kind, Two Pair, and Pair are broken by the highest card
        return compareHighCards(players, handType);
    } else {
        // High Card is broken by the highest card
        return compareHighCards(players, handType);
    }
}

function compareHighCards(address[] memory players, uint8 handType) internal view returns (address[] memory) {
    // Array to store the highest card for each player
    uint8[] memory highestCard = new uint8[](players.length);

    for (uint256 i = 0; i < players.length; i++) {
        uint256 playerCardIndex = playerCards[players[i]];
        uint8[] memory cards = new uint8[](7);
        cards[0] = tableCards[2 * playerCardIndex];
        cards[1] = tableCards[2 * playerCardIndex + 1];
        for (uint8 j = 0; j < 5; j++) {
            cards[j + 2] = tableCards[2 * players.length + j];
        }

        // Determine the highest card for the current player
        uint8 maxCard = 0;
        for (uint8 k = 0; k < 7; k++) {
            uint8 value = getValue(cards[k]);
            if (value > maxCard) {
                maxCard = value;
            }
        }
        highestCard[i] = maxCard;
    }

    // Find the maximum card value among all players
    uint8 maxCard = 0;
    for (uint256 i = 0; i < players.length; i++) {
        if (highestCard[i] > maxCard) {
            maxCard = highestCard[i];
        }
    }

    // Collect all players who have the highest card
    address[] memory winners = new address[](0);
    for (uint256 i = 0; i < players.length; i++) {
        if (highestCard[i] == maxCard) {
            winners.push(players[i]);
        }
    }

    return winners;
}

function compareFullHouses(address[] memory players) internal view returns (address[] memory) {
    // Arrays to store the values of the three of a kind and the pair for each player
    uint8[] memory threeOfAKindValue = new uint8[](players.length);
    uint8[] memory pairValue = new uint8[](players.length);

    for (uint256 i = 0; i < players.length; i++) {
        uint256 playerCardIndex = playerCards[players[i]];
        uint8[] memory cards = new uint8[](7);
        cards[0] = tableCards[2 * playerCardIndex];
        cards[1] = tableCards[2 * playerCardIndex + 1];
        for (uint8 j = 0; j < 5; j++) {
            cards[j + 2] = tableCards[2 * players.length + j];
        }

        // Count the occurrences of each card value
        uint8[] memory values = new uint8[](13);
        for (uint8 k = 0; k < 13; k++) values[k] = 0;
        for (uint8 k = 0; k < 7; k++) {
            uint8 value = getValue(cards[k]);
            values[value]++;
        }

        // Determine the three of a kind and the pair for the current player
        uint8 threeOfAKind = 0;
        uint8 pair = 0;
        for (uint8 k = 0; k < 13; k++) {
            if (values[k] == 3) {
                threeOfAKind = k;
            } else if (values[k] == 2) {
                pair = k;
            }
        }

        threeOfAKindValue[i] = threeOfAKind;
        pairValue[i] = pair;
    }

    // Find the maximum values of the three of a kind and the pair among all players
    uint8 maxThreeOfAKindValue = 0;
    uint8 maxPairValue = 0;
    for (uint256 i = 0; i < players.length; i++) {
        if (threeOfAKindValue[i] > maxThreeOfAKindValue) {
            maxThreeOfAKindValue = threeOfAKindValue[i];
            maxPairValue = pairValue[i];
        } else if (threeOfAKindValue[i] == maxThreeOfAKindValue && pairValue[i] > maxPairValue) {
            maxPairValue = pairValue[i];
        }
    }

    // Collect all players who have the highest three of a kind and pair
    address[] memory winners = new address[](0);
    for (uint256 i = 0; i < players.length; i++) {
        if (threeOfAKindValue[i] == maxThreeOfAKindValue && pairValue[i] == maxPairValue) {
            winners.push(players[i]);
        }
    }

    return winners;
}

function determineHand(uint8 player) internal view returns (uint8) {
    // Determine the hand ranking for the player
    // high card 0, pair 1, two pair 2, three of a kind 3, straight 4, flush 5, full house 6, four of a kind 7, straight flush 8, royal flush 9
    if (hasRoyalFlush(player)) return 9;
    else if (hasStraightFlush(player)) return 8;
    else if (hasMultipleOfAKind(player) == 4) return 7;
    else if (hasFullHouse(player)) return 6;
    else if (hasFlush(player)) return 5;
    else if (hasStraight(player)) return 4;
    else if (hasMultipleOfAKind(player) == 3) return 3;
    else if (hasTwoPair(player)) return 2;
    else if (hasMultipleOfAKind(player) == 2) return 1;
    return 0;
}

function hasStraight(uint8 player) internal view returns (bool) {
    // Check if the player has a straight
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

    uint8 consecutive = 0;
    for (uint8 i = 0; i < 13; i++) {
        if (values[i] > 0) {
            consecutive++;
            if (consecutive == 5) return true;
        } else {
            consecutive = 0;
        }
    }

    // Check the special case of A-2-3-4-5
    if (values[0] > 0 && values[1] > 0 && values[2] > 0 && values[3] > 0 && values[12] > 0) {
        return true;
    }

    return false;
}

function hasFullHouse(uint8 player) internal view returns (bool) {
    // Check if the player has a full house
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

    bool hasThree = false;
    bool hasTwo = false;

    for (uint8 i = 0; i < 13; i++) {
        if (values[i] == 3) hasThree = true;
        if (values[i] == 2) hasTwo = true;
    }

    return hasThree && hasTwo;
}

function hasStraightFlush(uint8 player) internal view returns (bool) {
    // Check if the player has a straight flush
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
        if (colors[i] > 4) {
            uint8[] memory values = new uint8[](13);
            for (uint8 j = 0; j < 13; j++) values[j] = 0;

            for (uint8 j = 0; j < 7; j++) {
                if (getColor(relevantCards[j]) == i) {
                    uint8 value = getValue(relevantCards[j]);
                    values[value]++;
                }
            }

            uint8 consecutive = 0;
            for (uint8 j = 0; j < 13; j++) {
                if (values[j] > 0) {
                    consecutive++;
                    if (consecutive == 5) return true;
                } else {
                    consecutive = 0;
                }
            }

            // Check the special case of A-2-3-4-5
            if (values[0] > 0 && values[1] > 0 && values[2] > 0 && values[3] > 0 && values[12] > 0) {
                return true;
            }
        }
    }

    return false;
}

function hasRoyalFlush(uint8 player) internal view returns (bool) {
    // Initialize an array to count the number of cards of each color
    uint8[] memory colors = new uint8[](4);
    for (uint8 i = 0; i < 4; i++) colors[i] = 0;

    // Collect the relevant cards for the player
    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
        relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    // Count the number of cards of each color
    for (uint8 i = 0; i < 7; i++) {
        uint8 color = getColor(relevantCards[i]);
        colors[color]++;
    }

    // Check for a royal flush in each color
    for (uint8 i = 0; i < 4; i++) {
        if (colors[i] > 4) {
            // Initialize an array to count the number of cards of each value
            uint8[] memory values = new uint8[](13);
            for (uint8 j = 0; j < 13; j++) values[j] = 0;

            // Count the number of cards of each value for the current color
            for (uint8 j = 0; j < 7; j++) {
                if (getColor(relevantCards[j]) == i) {
                    uint8 value = getValue(relevantCards[j]);
                    values[value]++;
                }
            }

            // Check for the presence of 10, J, Q, K, A
            if (values[10] > 0 && values[11] > 0 && values[12] > 0 && values[0] > 0 && values[9] > 0) {
                return true;
            }
        }
    }

    return false;
}

// Check if player has multiple of a kind, return multiplicity
function hasMultipleOfAKind(uint8 player) internal view returns (uint8) {
    // Initialize an array to count the number of cards of each value
    uint8[] memory values = new uint8[](13);
    for (uint8 i = 0; i < 13; i++) values[i] = 0;

    // Collect the relevant cards for the player
    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
        relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    // Count the number of cards of each value
    for (uint8 i = 0; i < 7; i++) {
        uint8 value = getValue(relevantCards[i]);
        values[value]++;
    }

    // Find the highest multiplicity of a kind
    uint8 highest = 0;
    for (uint8 i = 0; i < 13; i++) {
        if (values[i] > highest) highest = values[i];
    }

    return highest;
}

// Check if player has a flush
function hasFlush(uint8 player) internal view returns (bool) {
    // Initialize an array to count the number of cards of each color
    uint8[] memory colors = new uint8[](4);
    for (uint8 i = 0; i < 4; i++) colors[i] = 0;

    // Collect the relevant cards for the player
    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
        relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    // Count the number of cards of each color
    for (uint8 i = 0; i < 7; i++) {
        uint8 color = getColor(relevantCards[i]);
        colors[color]++;
    }

    // Check if there are more than 3 cards of any color
    for (uint8 i = 0; i < 4; i++) {
        if (colors[i] > 3) return true;
    }

    return false;
}

// Check if player has a two-pair
function hasTwoPair(uint8 player) internal view returns (bool) {
    // Initialize an array to count the number of cards of each value
    uint8[] memory values = new uint8[](13);
    for (uint8 i = 0; i < 13; i++) values[i] = 0;

    // Collect the relevant cards for the player
    uint8[] memory relevantCards = new uint8[](7);
    relevantCards[0] = tableCards[2 * player];
    relevantCards[1] = tableCards[2 * player + 1];
    for (uint8 i = 0; i < 5; i++) {
        relevantCards[i + 2] = tableCards[2 * players.length + i];
    }

    // Count the number of cards of each value
    for (uint8 i = 0; i < 7; i++) {
        uint8 value = getValue(relevantCards[i]);
        values[value]++;
    }

    // Count the number of pairs
    uint8 pairs = 0;
    for (uint8 i = 0; i < 13; i++) {
        if (values[i] > 1) pairs++;
    }

    return pairs > 1;
}

function getColor(uint8 card) internal pure returns (uint8) {
    // Extract the color from the card
    return card & 0x30;
}

function getValue(uint8 card) internal pure returns (uint8) {
    // Extract the value from the card
    return card & 0xf;
}

function isPlayer(address player) public view returns (bool) {
    // Check if the address is a player
    for (uint8 i = 0; i < players.length; i++) {
        if (players[i] == player) {
            return true;
        }
    }
    return false;
}

function playerIndex(address player) public view returns (uint8) {
    // Get the index of the player
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
    // Return the current game state
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

library RandomMock {
  function getFakeRandom() internal view returns (uint256) {
    // Generate a fake random number based on the block hash
    uint blockNumber = block.number;
    uint256 blockHash = uint256(blockhash(blockNumber));

    return blockHash;
  }

  function getFakeRandomU8() internal view returns (euint8) {
    // Generate a fake random uint8 number
    uint8 blockHash = uint8(getFakeRandom());
    return FHE.asEuint8(blockHash);
  }
}
