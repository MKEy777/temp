#pragma once
#include "event_handler.h"
#include "reactor.h"
#include "chat_server.h" 
#include "event_demultiplexer.h"

class ListenHandler : public EventHandler {
public:
    ListenHandler(int port, Reactor* sub_reactors, ChatServer* server); // (ÐÞ¸Ä)
    ~ListenHandler();
    virtual Handle get_handle() const;
    virtual void handle_read();
    virtual void handle_write();
    virtual void handle_error();
    virtual void handle_close();
private:
    void set_non_blocking(Handle fd);
    Handle listen_fd_;
    Reactor* sub_reactors_;
    ChatServer* chat_server_;
};