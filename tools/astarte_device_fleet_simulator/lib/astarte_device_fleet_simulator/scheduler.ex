#
# This file is part of Astarte.
#
# Copyright 2021 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule AstarteDeviceFleetSimulator.Scheduler do
  use GenServer, restart: :transient

  require Logger

  alias AstarteDeviceFleetSimulator.Device
  alias AstarteDeviceFleetSimulator.Config

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, Enum.into(Config.scheduler_opts(), %{}), {:continue, :init_messages}}
  end

  @impl true
  def handle_continue(:init_messages, state) do
    # not waiting all devices
    if state.allow_messages_while_spawning do
      check_scheduler_opts(state)

      Process.send_after(self(), :terminate, state.test_duration_s)
    end

    Logger.info("Begin device spawn.")
    Process.send(self(), :spawn, [])

    {:noreply, state}
  end

  @impl true
  def handle_cast(:device_spawn_end, state) do
    Logger.info("Device spawn ended.")

    # waiting all devices
    if not state.allow_messages_while_spawning do
      Process.send_after(self(), :terminate, state.test_duration_s)

      Registry.dispatch(AstarteDeviceFleetSimulator.Registry, "device", fn entries ->
        Enum.each(entries, fn {pid, _} -> :gen_statem.cast(pid, :begin_publishing) end)
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:spawn, %{device_count: 0} = state) do
    {:noreply, state}
  end

  def handle_info(:spawn, state) do
    Process.send_after(self(), :spawn, state.spawn_interval_ms)
    spawn_device(state.device_count, state.allow_messages_while_spawning)
    {:noreply, %{state | device_count: state.device_count - 1}}
  end

  def handle_info(:terminate, _state) do
    Logger.info("Simulation ended successfully.")
    System.stop(0)
    {:stop, {:shutdown, :simulation_ended}, %{}}
  end

  defp spawn_device(device_count, skip_waiting) do
    child = {Device, %{device_count: device_count, skip_waiting: skip_waiting}}
    DynamicSupervisor.start_child(DeviceSupervisor, child)
  end

  defp check_scheduler_opts(%{
         device_count: device_count,
         test_duration_s: test_duration_s,
         spawn_interval_ms: spawn_interval_ms
       }) do
    if test_duration_s <= device_count * spawn_interval_ms / 1000 do
      Logger.warning("Device spawn will not end before the end of the test. Errors may occur.",
        tag: "device_spawn_time_greater_than_test_duration"
      )
    end
  end
end
