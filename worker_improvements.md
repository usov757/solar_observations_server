# Улучшения обработки ошибок в MountWorker

## Текущие проблемы

1. **Нет health-check механизма**: Нельзя проверить состояние воркера
2. **Ограниченная обработка ошибок соединения**: При потере соединения нет детальной диагностики
3. **Нет мониторинга производительности**: Не отслеживается latency команд
4. **Жестко закодированные таймауты**: Нет адаптивных таймаутов

## Предлагаемые улучшения

### 1. Health-check API

Добавить функции для проверки состояния:

```elixir
@doc """
Проверяет состояние воркера.
Возвращает :ok если воркер работает и подключен к устройству.
"""
def health_check(timeout \\ 5000)

@doc """
Возвращает диагностическую информацию о состоянии воркера.
"""
def get_diagnostics()
```

### 2. Улучшенная обработка ошибок соединения

- Добавить счетчик переподключений
- Реализовать экспоненциальную задержку при повторных подключениях
- Добавить логирование причин сбоев

### 3. Мониторинг производительности

- Измерять время выполнения команд
- Собирать статистику успешных/неуспешных команд
- Отслеживать latency

### 4. Адаптивные таймауты

- Автоматически настраивать таймауты на основе истории выполнения
- Увеличивать таймауты для медленных команд
- Уменьшать таймауты для быстрых команд

### 5. Graceful shutdown

- Останавливать все команды при shutdown
- Завершать текущие операции
- Освобождать ресурсы

## Реализация

### Шаг 1: Добавить состояние для мониторинга

```elixir
def init({port_name, baud_rate, reconnect_interval}) do
  # ... существующий код ...

  {:ok,
   %{
     # ... существующие поля ...
     reconnect_attempts: 0,
     command_stats: %{
       total: 0,
       successful: 0,
       failed: 0,
       avg_latency: 0
     },
     last_error: nil,
     startup_time: DateTime.utc_now()
   }}
end
```

### Шаг 2: Реализовать health-check

```elixir
def health_check(timeout \\ 5000) do
  case GenServer.call(__MODULE__, :health_check, timeout) do
    {:ok, diagnostics} -> {:ok, diagnostics}
    error -> error
  end
end

# В handle_call:
def handle_call(:health_check, _from, state) do
  diagnostics = %{
    connected: state.connected,
    reconnect_attempts: state.reconnect_attempts,
    command_stats: state.command_stats,
    last_error: state.last_error,
    uptime: DateTime.diff(DateTime.utc_now(), state.startup_time, :second),
    port_name: state.port_name,
    baud_rate: state.baud_rate
  }

  {:reply, {:ok, diagnostics}, state}
end
```

### Шаг 3: Улучшить обработку переподключений

```elixir
defp reconnect(state) do
  # ... существующий код ...

  # Увеличиваем счетчик попыток
  attempts = state.reconnect_attempts + 1

  # Экспоненциальная задержка: 1s, 2s, 4s, 8s, ... max 30s
  delay = min(trunc(:math.pow(2, attempts - 1)) * 1000, 30000)

  Logger.warning("Reconnect attempt ##{attempts}, next in #{delay}ms")

  schedule_reconnect(delay)

  %{
    state
    | connected: false,
      current_request: nil,
      request_queue: [],
      response_buffer: "",
      reconnect_attempts: attempts,
      last_error: :connection_lost
  }
end
```

### Шаг 4: Добавить мониторинг команд

```elixir
defp execute_command(state, from, command, timeout) do
  start_time = System.monotonic_time(:millisecond)

  # ... существующий код ...

  # После выполнения команды обновляем статистику
  Process.send_after(self(), {:update_stats, from, command, start_time}, 0)

  # ... возвращаем обновленное состояние ...
end

def handle_info({:update_stats, from, command, start_time}, state) do
  latency = System.monotonic_time(:millisecond) - start_time

  stats = state.command_stats
  total = stats.total + 1

  # Обновляем среднюю latency (скользящее среднее)
  avg_latency = if stats.total > 0 do
    (stats.avg_latency * stats.total + latency) / total
  else
    latency
  end

  new_stats = %{
    stats
    | total: total,
      avg_latency: avg_latency
  }

  {:noreply, %{state | command_stats: new_stats}}
end
```

## Приоритеты

1. **Высокий**: Health-check API и улучшенная обработка ошибок
2. **Средний**: Мониторинг производительности
3. **Низкий**: Адаптивные таймауты

## Тестирование

Добавить тесты для:

1. Health-check при работающем соединении
2. Health-check при разорванном соединении
3. Переподключение после сбоя
4. Статистика команд
