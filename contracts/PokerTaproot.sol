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
uint8 public dealerIndex;
bool public gameEnded;
uint256 public smallBlind;
unit256 public bigBlind;
    uint256 public constant ACTION_TIMEOUT = 1 minutes;
    mapping(address => uint256) public lastActionTimestamp;


    ///events

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

  constructor() {
    currentPlayer = address(0);
    currentRound = 0;
    currentBet = 0;
    pot = 0;
    gameEnded = false;
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

    emit PlayerJoined(msg.sender);
  }
     function setBlindValues(uint256 _smallBlind, uint256 _bigBlind) public onlyOwner {
        smallBlind = _smallBlind;
        bigBlind = _bigBlind;
    }

function setBlinds(uint256 smallBlind, uint256 bigBlind) internal {
    require(players.length >= 2, "Not enough players to set blinds");
    
    uint8 smallBlindIndex = (dealerIndex + 1) % uint8(players.length);
    uint8 bigBlindIndex = (dealerIndex + 2) % uint8(players.length);
    
    // Small blind
    if (currentStack[players[smallBlindIndex]] >= smallBlind) {
        currentStack[players[smallBlindIndex]] -= smallBlind;
        pot += smallBlind;
    } else {
        // All-in for small blind
        pot += currentStack[players[smallBlindIndex]];
        currentStack[players[smallBlindIndex]] = 0;
    }
    
    // Big blind
    if (currentStack[players[bigBlindIndex]] >= bigBlind) {
        currentStack[players[bigBlindIndex]] -= bigBlind;
        pot += bigBlind;
        currentBet = bigBlind;
    } else {
        // All-in for big blind
        pot += currentStack[players[bigBlindIndex]];
        currentBet = currentStack[players[bigBlindIndex]];
        currentStack[players[bigBlindIndex]] = 0;
    }
    
    currentPlayer = players[(dealerIndex + 3) % players.length];
}

function removePlayer(address player) internal {
    for (uint256 i = 0; i < players.length; i++) {
        if (players[i] == player) {
            players[i] = players[players.length - 1];
            players.pop();
            break;
        }
    }
}

function startGame() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(players.length > 1, "Not enough players to start the game");
    require(cards.length == 0, "Game already started");
    require(playerIndex(msg.sender) == 0, "Only the first player can start the game");

    dealerIndex = 0; // Inicializar el dealer
    deal();
    setBlinds(smallBlind, bigBlind);
    currentPlayer = players[(dealerIndex + 3) % players.length];
    emit GameStarted();
}

  function check() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(stillPlaying[msg.sender], "You are not in the game");
    require(currentPlayer == msg.sender, "It's not your turn");
    require(currentBet == 0, "You cannot check, there is a bet");
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout");

    lastActionTimestamp[msg.sender] = block.timestamp;

    uint8 index = (playerIndex(msg.sender) + 1) % uint8(players.length);
    currentPlayer = players[index];
        advanceTurn();
    if (playerIndex(currentPlayer) == 0) {
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
        emit PlayerChecked(msg.sender);
    }
}

function leaveGame() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(!stillPlaying[msg.sender], "You cannot leave while still playing a hand");

    uint256 amount = currentStack[msg.sender];
    currentStack[msg.sender] = 0;
    removePlayer(msg.sender);

    payable(msg.sender).transfer(amount);

    // Si el jugador que se retira es el jugador actual, avanzar al siguiente jugador
    if (currentPlayer == msg.sender) {
        advanceTurn();
    }

    // Si no hay suficientes jugadores para continuar, terminar el juego
    if (players.length < 2) {
        gameEnded = true;
    }
    emit PlayerLeft(msg.sender);
}

function call() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(stillPlaying[msg.sender], "You are not in the game");
    require(currentPlayer == msg.sender, "It's not your turn");
    require(currentBet > 0, "There is no bet to call");
    require(currentStack[msg.sender] >= currentBet, "You don't have enough money to call");
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout");
    lastActionTimestamp[msg.sender] = block.timestamp;

    currentStack[msg.sender] -= currentBet;
    pot += currentBet;

    uint8 index = (playerIndex(msg.sender) + 1) % uint8(players.length);
    currentPlayer = players[index];
        advanceTurn();
    if (playerIndex(currentPlayer) == 0) {
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
        emit PlayerCalled(msg.sender);
    }
}
function advanceTurn() internal {
    uint8 index = (playerIndex(currentPlayer) + 1) % uint8(players.length);
    currentPlayer = players[index];
}

function endRound() internal {
    // Eliminar jugadores con stack 0
    for (uint256 i = 0; i < players.length; i++) {
        if (currentStack[players[i]] == 0) {
            removePlayer(players[i]);
            i--; // Ajustar el índice después de eliminar un elemento
        }
    }

       if (players.length < 2) {
        // Terminar el juego y otorgar el bote al último jugador con fichas
        if (players.length == 1) {
            currentStack[players[0]] += pot;
            pot = 0;
        }
        // Reiniciar el juego
        gameEnded = true;
        return;
    }

    dealerIndex = (dealerIndex + 1) % uint8(players.length);
    setBlinds(0.00000005 ether, 0.0000001 ether);
    currentPlayer = players[(dealerIndex + 3) % players.length];
    currentRound = 0;

    // Reiniciar las variables para la nueva ronda
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
        emit PlayerBet(msg.sender, betAmount);
    }

    // Verificar si sólo queda un jugador con fichas
    uint256 playersWithChips = 0;
    address lastPlayerWithChips;
    for (uint256 i = 0; i < players.length; i++) {
        if (currentStack[players[i]] > 0) {
            playersWithChips++;
            lastPlayerWithChips = players[i];
        }
    }

    if (playersWithChips == 1) {
        // Terminar la mano y otorgar el bote al último jugador con fichas
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
            // El jugador actual no realizó una acción dentro del tiempo límite
            if (currentBet == 0) {
                // No hay apuesta actual, realizar un "check" automático
                lastActionTimestamp[currentPlayer] = block.timestamp;
                emit AutoCheck(currentPlayer);
            } else {
                // Hay una apuesta, realizar un "fold" automático
                stillPlaying[currentPlayer] = false;
                emit AutoFold(currentPlayer);
            }
        }

        currentPlayer = nextPlayer;
    }

    event AutoCheck(address indexed player);
    event AutoFold(address indexed player);
}

  function fold() public {
    require(isPlayer(msg.sender), "You are not in the game");
    require(stillPlaying[msg.sender], "You are not in the game");
    require(currentPlayer == msg.sender, "It's not your turn");
    require(currentRound < 4, "Game is over");
    require(block.timestamp <= lastActionTimestamp[msg.sender] + ACTION_TIMEOUT, "Action timeout");
    lastActionTimestamp[msg.sender] = block.timestamp;

    stillPlaying[msg.sender] = false;

    advanceTurn();
    if (playerIndex(currentPlayer) == 0) {
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
      emit PlayerFolded(msg.sender);
    }
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

    function distributePot(address[] memory winners) internal {
    // distribute pot to winners
    for (uint8 i = 0; i < winners.length; i++) {
      currentStack[winners[i]] += pot / winners.length;
      emit PotDistributed(winners[i], potShare);
    }
    pot = 0;
    endRound();
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
    address[] memory highestHandPlayers = new address[](0);
    uint256 highestHandCount = 0;

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

   // Lógica de desempate
    if (highestHandCount > 1) {
        highestHandPlayers = breakTies(highestHandPlayers);
    }

    // Distribución del bote
    uint256[] memory potentialWinnings = new uint256[](players.length);
    for (uint256 i = 0; i < players.length; i++) {
        address player = players[i];
        if (stillPlaying[player]) {
            potentialWinnings[i] = currentBet - (currentBet - currentStack[player]);
        }
    }

    // Distribuir el bote considerando all-ins
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
        // Escalera Real, Escalera de Color y Color se desempatan por la carta más alta
        return compareHighCards(players, handType);
    } else if (handType == 7 || handType == 4) {
        // Póker y Escalera se desempatan por la carta más alta
        return compareHighCards(players, handType);
    } else if (handType == 6) {
        // Full House se desempata por el trío, luego por la pareja
        return compareFullHouses(players);
    } else if (handType == 3 || handType == 2 || handType == 1) {
        // Trío, Doble Pareja y Pareja se desempatan por la carta más alta
        return compareHighCards(players, handType);
    } else {
        // Carta Alta se desempata por la carta más alta
        return compareHighCards(players, handType);
    }
}

function compareHighCards(address[] memory players, uint8 handType) internal view returns (address[] memory) {
    uint8[] memory highestCard = new uint8[](players.length);

    for (uint256 i = 0; i < players.length; i++) {
        uint256 playerCardIndex = playerCards[players[i]];
        uint8[] memory cards = new uint8[](7);
        cards[0] = tableCards[2 * playerCardIndex];
        cards[1] = tableCards[2 * playerCardIndex + 1];
        for (uint8 j = 0; j < 5; j++) {
            cards[j + 2] = tableCards[2 * players.length + j];
        }
        
        uint8 maxCard = 0;
        for (uint8 k = 0; k < 7; k++) {
            uint8 value = getValue(cards[k]);
            if (value > maxCard) {
                maxCard = value;
            }
        }
        highestCard[i] = maxCard;
    }

    uint8 maxCard = 0;
    for (uint256 i = 0; i < players.length; i++) {
        if (highestCard[i] > maxCard) {
            maxCard = highestCard[i];
        }
    }

    address[] memory winners = new address[](0);
    for (uint256 i = 0; i < players.length; i++) {
        if (highestCard[i] == maxCard) {
            winners.push(players[i]);
        }
    }

    return winners;
}

function compareFullHouses(address[] memory players) internal view returns (address[] memory) {
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
        
        uint8[] memory values = new uint8[](13);
        for (uint8 k = 0; k < 13; k++) values[k] = 0;
        
        for (uint8 k = 0; k < 7; k++) {
            uint8 value = getValue(cards[k]);
            values[value]++;
        }
        
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

    address[] memory winners = new address[](0);
    for (uint256 i = 0; i < players.length; i++) {
        if (threeOfAKindValue[i] == maxThreeOfAKindValue && pairValue[i] == maxPairValue) {
            winners.push(players[i]);
        }
    }

    return winners;
}


function determineHand(uint8 player) internal view returns (uint8) {
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

    // Verificar el caso especial de A-2-3-4-5
    if (values[0] > 0 && values[1] > 0 && values[2] > 0 && values[3] > 0 && values[12] > 0) {
        return true;
    }

    return false;
}

  function hasFullHouse(uint8 player) internal view returns (bool) {
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

            // Verificar el caso especial de A-2-3-4-5
            if (values[0] > 0 && values[1] > 0 && values[2] > 0 && values[3] > 0 && values[12] > 0) {
                return true;
            }
        }
    }

    return false;
}

function hasRoyalFlush(uint8 player) internal view returns (bool) {
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

            if (values[10] > 0 && values[11] > 0 && values[12] > 0 && values[0] > 0 && values[9] > 0) {
                return true;
            }
        }
    }

    return false;
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
