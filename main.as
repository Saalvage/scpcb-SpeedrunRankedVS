using namespace B3D;
using namespace CB;

namespace Steam {
    uint64 GetSenderID() {
        return (uint64(GetSenderIDUpper()) << 32) | GetSenderIDLower();
    }

    uint64 StringToID(string str) {
        return (uint64(StringToIDUpper(str)) << 32) | StringToIDLower(str);
    }

    bool SendPackage(uint64 id) {
        return SendPacketToUser(id >> 32, id & 0xFFFFFFFF);
    }

    void CloseConnection(uint64 id) {
        CloseConnection(id >> 32, id & 0xFFFFFFFF);
    }

    uint64 GetLobbyMemberID(int index) {
        return (uint64(GetLobbyMemberIDUpper(index)) << 32) | GetLobbyMemberIDLower(index);
    }

    uint64 GetLobbyOwnerID() {
        return (uint64(GetLobbyOwnerIDUpper()) << 32) | GetLobbyOwnerIDLower();
    }

    uint64 GetPlayerID() {
        return (uint64(GetPlayerIDUpper()) << 32) | GetPlayerIDLower();
    }

    string GetOtherPlayerName(uint64 id) {
        return GetOtherPlayerName(id >> 32, id & 0xFFFFFFFF);
    }
}

enum ConnectionState {
    Disconnected,
    InLobby,
    Connected,
    Loading,
    LoadingFinishedWaiting,
}

enum PlayerState {
    Idle,
    Walking,
    Running,
    CrouchedIdle,
    CrouchedWalking,
    Dead,
}

uint64 myID;
uint64 partnerID = 0;
bool connected = false;
bool isLoading = false;
bool peerIsReady = false;
int gameStartSend = 0;
int gameStartActual = 0;

int mySkinIdx;
int peerSkinIdx;

int sentId = 0;
int lastReceivedId = 0;
NPC@ ghost;

int peerFinishTimeMs = 0;
bool hasFinished = false;

enum PacketType {
    GameInfoUpdate,
    Acc,
    StartLoad,
    Ready,
    GameStart,
    GameStartResponse,
    PlayerState,
    Finish,
};

void Hook_Initialize() {
    myID = Steam::GetPlayerID();
}

void UpdatePartnerID(uint64 newPartnerID) {
    if (partnerID == newPartnerID) { return; }

    if (partnerID != 0) {
        Steam::CloseConnection(partnerID);
    }
    partnerID = newPartnerID;
    connected = false;
    if (partnerID != 0 && Steam::GetLobbyOwnerID() == myID) {   
        SendGameInfoUpdate();
    }
}

// Network seed state.
bool currHasNumericSeed;
string currSeed = "";
int currSeedNumeric;

void SendGameInfoUpdate() {
    Steam::PushByte(PacketType::GameInfoUpdate);
    Steam::PushByte(HasNumericSeed ? 1 : 0);
    if (HasNumericSeed) {
        Steam::PushInt(RandomSeedNumeric);
    } else {
        Steam::PushString(CB::RandomSeed);
    }
    Steam::SendPackage(partnerID);

    currHasNumericSeed = HasNumericSeed;
    currSeed = CB::RandomSeed;
    currSeedNumeric = RandomSeedNumeric;
}

void CheckSettingsConsistency() {
    if (!connected) { return; }

    if (Steam::GetLobbyOwnerID() == myID) {
        if (currHasNumericSeed != HasNumericSeed || (currHasNumericSeed ? (currSeedNumeric != RandomSeedNumeric) : (currSeed != CB::RandomSeed))) {
            SendGameInfoUpdate();
        }
    } else {
        HasNumericSeed = currHasNumericSeed;
        if (currHasNumericSeed) {
            RandomSeedNumeric = currSeedNumeric;
        } else {
            CB::RandomSeed = currSeed;
        }
    }
}

void HandlePacket() {
    uint8 b = Steam::PullByte();
    uint64 senderID = Steam::GetSenderID();
    if (partnerID != senderID) {
        Steam::CloseConnection(partnerID);
    } else {
        if (b == PacketType::GameInfoUpdate) {
            currHasNumericSeed = Steam::PullByte() != 0;
            if (currHasNumericSeed) {
                currSeedNumeric = Steam::PullInt();
            } else {
                currSeed = Steam::PullString();
            }

            if (!connected) {
                connected = true;
                Steam::PushByte(PacketType::Acc);
                Steam::SendPackage(partnerID);
            }
        } else if (b == PacketType::Acc) {
            connected = true;
        } else if (b == PacketType::StartLoad) {
            isLoading = true;
            Menu::StartNewGame();
        } else if (b == PacketType::Ready) {
            peerIsReady = true;
        } else if (b == PacketType::GameStart) {
            // If both send concurrently, the owner doesn't send a response.
            if (gameStartSend != 0 && Steam::GetLobbyOwnerID() == myID) {
                return;
            }
            peerSkinIdx = Steam::PullByte();

            Steam::PushByte(PacketType::GameStartResponse);
            Steam::PushByte(mySkinIdx);
            Steam::SendPackage(partnerID);
            gameStartActual = MilliSecs();
        } else if (b == PacketType::GameStartResponse) {
            int now = MilliSecs();
            gameStartActual = now - (now - gameStartSend) / 2;
            peerSkinIdx = Steam::PullByte();
        } else if (b == PacketType::PlayerState) {
            int id = Steam::PullInt();
            if (id <= lastReceivedId) {
                return;
            }
            lastReceivedId = id;
            float x = Steam::PullFloat();
            float y = Steam::PullFloat();
            float z = Steam::PullFloat();
            ghost.Collider.Position(x, y, z);
            
            float yaw = Steam::PullFloat();
            ghost.Collider.Rotate(0, yaw, 0);

            ghost.State2 = Steam::PullByte();
        } else if (b == PacketType::Finish) {
            peerFinishTimeMs = Steam::PullInt();
        }
    }
}

void UpdateMenu() {
    if (Menu::MainMenuTab == 1) {
        float x = 740 * Menu::Scale;
        float y = 366 * Menu::Scale;

        if (connected) {
            SetColor(0, 255, 0);
        } else {
            SetColor(255, 255, 255);
        }

        Menu::DrawFrame(x, y, 420 * Menu::Scale, 305 * Menu::Scale);
        
        if (Menu::DrawButton(x + 20 * Menu::Scale, y + 50 * Menu::Scale, 185 * Menu::Scale, 40 * Menu::Scale, "Invite", false)) {
            Steam::ActivateOverlayInviteDialog();
        }

        if (Steam::LoadPacket() == 1) {
            HandlePacket();
        }

        if (connected) {
            CheckSettingsConsistency();
        }

        int state = Steam::GetLobbyState();
        string msg;
        if (state == 0) {
            Steam::CreateLobby(1, 2);
        } else if (state > 10) {
            msg = "Creating lobby...";
        } else if (state < 0) {
            msg = "Error: " + ToString(-state);
        } else {
            if (Steam::GetNumLobbyMembers() > 1) {
                uint64 newPartnerID;
                for (int i = 0; i < 2; i++) {
                    uint64 id = Steam::GetLobbyMemberID(i);
                    if (id != myID) {
                        newPartnerID = id;
                        break;
                    }
                }

                UpdatePartnerID(newPartnerID);
                
                if (connected) {
                    msg = "Connected to " + Steam::GetOtherPlayerName(newPartnerID) + "!";
                } else {
                    msg = "Connecting to " + Steam::GetOtherPlayerName(newPartnerID) + "...";
                }

                if (Menu::DrawButton(x + (20 + 195) * Menu::Scale, y + 50 * Menu::Scale, 185 * Menu::Scale, 40 * Menu::Scale, "Leave", false)) {
                    Steam::LeaveLobby();
                    UpdatePartnerID(0);
                }

            } else {
                UpdatePartnerID(0);
                msg = "Waiting for peer.";
            }
        }

        Text(x + 20 * Menu::Scale, y + 125 * Menu::Scale, "Skin:", 0, 1);
        mySkinIdx = Min(Max(Menu::InputBox(x + 100 * Menu::Scale, y + 110 * Menu::Scale, 40 * Menu::Scale, 30 * Menu::Scale, ToString(mySkinIdx), 66).ParseInt(), 0), 8);

        Text(x + 20 * Menu::Scale, y + 20 * Menu::Scale, msg);
    } else if (partnerID != 0) {
        Steam::LeaveLobby();
        UpdatePartnerID(0);
    }
}

void UpdateGame() {
    if (!connected) { return; }

    Steam::PushByte(PacketType::PlayerState);
    Steam::PushInt(++sentId);
    Steam::PushFloat(Player::Collider.GetX());
    Steam::PushFloat(Player::Collider.GetY());
    Steam::PushFloat(Player::Collider.GetZ());
    Steam::PushFloat(Player::Collider.GetYaw());
    Steam::PushByte(Player::KillTimer < 0 ? PlayerState::Dead
        : Player::Crouch
            ? Player::CurrentSpeed > 0 ? PlayerState::CrouchedWalking : PlayerState::CrouchedIdle
            : Player::CurrentSpeed > 0
                ? Player::Stamina > 0 && KeyDown(Options::KeySprint) ? PlayerState::Running : PlayerState::Walking
                : PlayerState::Idle);
    Steam::SendPackage(partnerID);

    while (Steam::LoadPacket() == 1) {
        HandlePacket();
    }

    switch (PlayerState(ghost.State2)) {
        case PlayerState::Idle:
            ghost.Animate(210, 235, 0.1);
            break;
        case PlayerState::Walking:
            ghost.Animate(236, 260, 0.3);
            break;
        case PlayerState::Running:
            ghost.Animate(301, 319, 0.5);
            break;
        case PlayerState::CrouchedIdle:
            ghost.Animate(357, 381, 0.1);
            break;
        case PlayerState::CrouchedWalking:
            ghost.Animate(382, 406, 0.3);
            break;
        case PlayerState::Dead:
            ghost.Animate(0, 20, 0.1, false);
            break;
    }

    if (!hasFinished && TimerStopped == 3) {
        hasFinished = true;
        Steam::PushByte(PacketType::Finish);
        Steam::PushInt(PlayTime);
        Steam::SendPackage(partnerID);
    }

    if (hasFinished || peerFinishTimeMs != 0) {
        bool isWinner = hasFinished && (peerFinishTimeMs == 0 || PlayTime <= peerFinishTimeMs);
        SetColor(isWinner ? 0 : 255, isWinner ? 255 : 0, 0);
        Text(Options::GraphicWidth / 2, 10, isWinner ? "You win!" : "You lose!", 1);
        if (peerFinishTimeMs != 0) {
            Text(Options::GraphicWidth / 2, 30, Steam::GetOtherPlayerName(partnerID) + "'s time: " + FormatDuration(peerFinishTimeMs), 1);
        }
    }
}

void Hook_Update() {
    if (Menu::IsMainMenuOpen) {
        UpdateMenu();
    } else {
        UpdateGame();
    }
}

void Hook_LoadEntities() {
    if (!connected) { return; }

    peerIsReady = false;
    if (!isLoading) {
        Steam::PushByte(PacketType::StartLoad);
        Steam::SendPackage(partnerID);
        isLoading = true;
    }
}

void CreateGhost() {
    @ghost = NPC(NPC::Type::ClassD, Player::Collider.GetX(), Player::Collider.GetY() + 1.0, Player::Collider.GetZ());
    ghost.State = 99;
    if (mySkinIdx > 0) {
        ghost.ChangeNPCTexture(mySkinIdx - 1);
    }
    cast<Mesh@>(ghost.Object).Alpha = 0.5;
    ghost.Collider.Hide();
    ghost.GravityMultiplier = 0;
}

const int secondsToStart = 3;

void Hook_PostLoad() {
    if (isLoading) {
        isLoading = false;
        gameStartSend = 0;
        gameStartActual = 0;

        sentId = 0;
        lastReceivedId = 0;

        peerFinishTimeMs = 0;
        hasFinished = false;

        CreateGhost();

        Steam::PushByte(PacketType::Ready);
        Steam::SendPackage(partnerID);
        
        while (true) {
            Cls();

            if (Steam::LoadPacket() == 1) {
                HandlePacket();
            }

            if (peerIsReady) {
                if (gameStartActual == 0) {
                    Text(10, 10, "Press any key to continue.");
                    if (gameStartSend == 0 && (GetKey() != 0 || MouseHit(1) != 0)) {
                        Steam::PushByte(PacketType::GameStart);
                        Steam::PushByte(mySkinIdx);
                        Steam::SendPackage(partnerID);
                        gameStartSend = MilliSecs();
                    }
                } else {
                    int now = MilliSecs();
                    Text(10, 10, "Starting in " + ToString(secondsToStart - (now - gameStartActual) / 1000) + "...");
                    if (now - gameStartActual >= secondsToStart * 1000) {
                        break;
                    }
                }
            } else {
                Text(10, 10, "Waiting for peer...");
            }

            Flip(1);

            Steam::Update();
        }
    }
}

// Gate B wants to take our ghost away! We can't have that.
bool Hook_RemoveNPC(NPC@ n) {
    return n is ghost;
}
