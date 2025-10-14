#pragma once
#include "event_handler.h"
#include <functional>

class ReactorImplementation;

class Reactor {
private:
    ReactorImplementation* impl;

public:
    Reactor();
    ~Reactor();

    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    void event_loop();
    void quit(); // 退出事件循环

    void queue_in_loop(std::function<void()> task);
};