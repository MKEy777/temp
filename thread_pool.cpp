#include "thread_pool.h"

ThreadPool::ThreadPool(size_t threads) : stop(false) {
    for (size_t i = 0; i < threads; ++i) {
        workers.emplace_back([this] {
            while (true) {
                std::function<void()> task; // 用于存储待执行的任务
                {
                    // 使用 unique_lock 自动管理互斥锁的加锁和解锁
                    std::unique_lock<std::mutex> lock(queue_mutex);
                    condition.wait(lock, [this] {
                        return stop || !tasks.empty();// continue until return true
                        });
                    if (stop && tasks.empty()) {
                        return;
                    }
                    task = std::move(tasks.front());
                    tasks.pop();
                } // 锁的作用域结束，自动解锁
                task();
            }
            });
    }
}

ThreadPool::~ThreadPool() {
    {
        std::unique_lock<std::mutex> lock(queue_mutex);
        stop = true;
    } 

    // 唤醒所有等待中的线程，让它们检查 stop 标志并退出循环
    condition.notify_all();

    for (std::thread& worker : workers) {
        worker.join();
    }
}

// 添加新任务到队列
void ThreadPool::enqueue(std::function<void()> task) {
    {
        std::unique_lock<std::mutex> lock(queue_mutex);
        if (stop) {
            return;
        }
        tasks.emplace(task);
    } 

    condition.notify_one();
}