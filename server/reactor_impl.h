#pragma once
#include "epoll_demultiplexer.h"
#include "event_handler.h"
#include <map>
#include <mutex>
#include <vector>
#include <functional>

class ReactorImplementation {
private:
    EventDemultiplexer* demux;
    std::map<Handle, EventHandler*> handlers;
    std::mutex handlers_mutex;
    bool running_; // ����״̬

    // --- eventfd ��� ---
    int wakeup_fd_;
    EventHandler* wakeup_handler_;
    void handle_wakeup();
    // --------------------

    std::mutex tasks_mutex_;
    std::vector<std::function<void()>> pending_tasks_;
    void do_pending_tasks();

public:
    ReactorImplementation();
    ~ReactorImplementation();

    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    void event_loop();
    void quit(); // �˳��¼�ѭ��

    void queue_in_loop(std::function<void()> task);
};