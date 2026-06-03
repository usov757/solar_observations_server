defmodule SolarObservations.Event do
  @moduledoc """
  Контекст для работы с сессиями наблюдений и их событиями.

  start_session/2 и sync_session/1 содержат оркестрацию железа —
  последовательность команд с логированием каждого шага как SessionEvent.
  """

  alias SolarObservations.{Device, ObservingSession, Repo, SessionEvent}
  import Ecto.Query

  @session_preloads [:mount, :session_events]

  # ---------------------------------------------------------------------------
  # ObservingSession: CRUD
  # ---------------------------------------------------------------------------

  def list_sessions do
    Repo.all(ObservingSession) |> Repo.preload(@session_preloads)
  end

  def list_sessions_by_mount(mount_id) do
    Repo.all(
      from s in ObservingSession,
        where: s.mount_id == ^mount_id,
        preload: ^@session_preloads
    )
  end

  def get_session!(id), do: Repo.get!(ObservingSession, id) |> Repo.preload(@session_preloads)

  def create_session(attrs) do
    with {:ok, session} <- %ObservingSession{} |> ObservingSession.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(session, @session_preloads)}
    end
  end

  def update_session(%ObservingSession{} = session, attrs) do
    with {:ok, session} <- session |> ObservingSession.changeset(attrs) |> Repo.update() do
      {:ok, Repo.preload(session, @session_preloads)}
    end
  end

  def delete_session(%ObservingSession{} = session), do: Repo.delete(session)

  def end_session(%ObservingSession{} = session) do
    update_session(session, %{ended_at: DateTime.utc_now(), status: "completed"})
  end

  def abort_session(%ObservingSession{} = session) do
    update_session(session, %{status: "aborted"})
  end

  # ---------------------------------------------------------------------------
  # ObservingSession: оркестрация железа
  # ---------------------------------------------------------------------------

  @doc """
  Полный цикл запуска сессии наблюдений:
    1. initialize (ось из params или "3")
    2. goto_sun
    3. start_tracking (берёт cpr/timer_freq из mount или из params)
    4. start_camera_stream

  Каждый шаг логируется как SessionEvent.
  При ошибке на любом шаге — сессия переводится в статус "aborted",
  логируется событие ошибки, возвращается {:error, step, reason}.

  params — опциональная карта:
    %{
      axis: "3",             # ось для initialize, по умолчанию "3"
      cpr: integer,          # CPR для трекинга, если nil — берётся из mount
      timer_freq: integer    # timer_freq для трекинга, если nil — берётся из mount
    }
  """
  def start_session(%ObservingSession{} = session, params \\ %{}) do
    mount = session.mount
    axis = Map.get(params, "axis", "3")

    steps = [
      {:initialize, fn -> Device.initialize_mount(axis) end},
      {:goto_sun, fn -> Device.goto_sun(mount) end},
      {:start_tracking, fn ->
        case {Map.get(params, "cpr"), Map.get(params, "timer_freq")} do
          {nil, nil} -> Device.start_tracking(mount)
          {cpr, freq} -> Device.start_tracking_with_params(cpr || mount.cpr_ra, freq || mount.timer_freq)
        end
      end},
      {:start_camera_stream, fn ->
        camera_id = get_primary_camera_id(mount)
        Device.start_camera_stream(camera_id)
      end}
    ]

    run_session_steps(session, steps)
  end

  @doc """
  Синхронизирует текущую позицию монтировки с расчётной позицией Солнца.
  Логирует результат как SessionEvent типа "sync".
  """
  def sync_session(%ObservingSession{} = session) do
    started_at = DateTime.utc_now()

    case Device.sync_to_sun() do
      {:ok, result} ->
        log_event(session.id, "sync", %{
          "raw_response" => inspect(result),
          "success" => true,
          "message" => "Sync to Sun completed"
        })
        {:ok, session}

      {:error, reason} ->
        log_event(session.id, "error", %{
          "raw_response" => inspect(reason),
          "success" => false,
          "message" => "Sync failed: #{inspect(reason)}"
        })
        {:error, :sync_failed, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # SessionEvent: CRUD
  # ---------------------------------------------------------------------------

  def list_events do
    Repo.all(SessionEvent) |> Repo.preload(:observing_session)
  end

  def list_events_by_session(session_id) do
    get_session!(session_id)

    Repo.all(
      from e in SessionEvent,
        where: e.observing_session_id == ^session_id,
        preload: :observing_session
    )
  end

  def get_event!(id), do: Repo.get!(SessionEvent, id) |> Repo.preload(:observing_session)

  def create_event(attrs) do
    with {:ok, event} <- %SessionEvent{} |> SessionEvent.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(event, :observing_session)}
    end
  end

  def update_event(%SessionEvent{} = event, attrs) do
    with {:ok, event} <- event |> SessionEvent.changeset(attrs) |> Repo.update() do
      {:ok, Repo.preload(event, :observing_session)}
    end
  end

  def delete_event(%SessionEvent{} = event), do: Repo.delete(event)

  def create_typed_event(session_id, event_type, params) do
    attrs = %{
      occurred_at: DateTime.utc_now(),
      event_type: event_type,
      raw_command: params["raw_command"],
      raw_response: params["raw_response"],
      success: Map.get(params, "success", event_type != "error"),
      message: params["message"],
      observing_session_id: session_id
    }

    create_event(attrs)
  end

  # ---------------------------------------------------------------------------
  # Приватные
  # ---------------------------------------------------------------------------

  # Последовательно выполняет шаги, логирует каждый.
  # При первой ошибке останавливается, переводит сессию в aborted.
  defp run_session_steps(%ObservingSession{} = session, steps) do
    Enum.reduce_while(steps, {:ok, session}, fn {step_name, step_fn}, {:ok, acc_session} ->
      case step_fn.() do
        {:ok, result} ->
          log_event(acc_session.id, to_string(step_name), %{
            "raw_response" => inspect(result),
            "success" => true,
            "message" => "#{step_name} completed"
          })
          {:cont, {:ok, acc_session}}

        :ok ->
          log_event(acc_session.id, to_string(step_name), %{
            "success" => true,
            "message" => "#{step_name} completed"
          })
          {:cont, {:ok, acc_session}}

        {:error, reason} ->
          log_event(acc_session.id, "error", %{
            "raw_response" => inspect(reason),
            "success" => false,
            "message" => "#{step_name} failed: #{inspect(reason)}"
          })
          {:ok, _} = abort_session(acc_session)
          {:halt, {:error, step_name, reason}}
      end
    end)
    |> case do
      {:ok, session} ->
        update_session(session, %{status: "active", started_at: DateTime.utc_now()})

      error ->
        error
    end
  end

  defp log_event(session_id, event_type, params) do
    create_typed_event(session_id, event_type, params)
  end

  # Берёт первую камеру, привязанную к монтировке.
  # При необходимости логику можно усложнить (primary camera flag и т.п.).
  defp get_primary_camera_id(%{id: mount_id}) do
    case Device.list_cameras_by_mount(mount_id) do
      [camera | _] -> camera.id
      [] -> raise "No cameras attached to mount #{mount_id}"
    end
  end
end
