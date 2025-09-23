#pragma once

#include "event_handler.h"

class ReactorImplementation;  // Ç°ÏòÉùÃ÷

class Reactor {
private:
    ReactorImplementation* impl;

public:
    Reactor();
    ~Reactor();

    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    void event_loop(int timeout = 0);
};