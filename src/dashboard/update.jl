"""
Event handling for the dashboard.
"""

function Tachikoma.update!(m::ProgressDashboard, evt::KeyEvent)
    # Modal open: only handle modal keys
    if m.confirm_mark_failed_id !== nothing
        confirm_mark_failed_id = m.confirm_mark_failed_id
        if evt.key == :escape || (evt.key == :char && evt.char == 'c')
            m.confirm_mark_failed_id = nothing
            return
        end
        if evt.key == :left || (evt.key == :char && evt.char == 'h')
            m.confirm_modal_selected = m.confirm_modal_selected == :confirm ? :cancel : :confirm
            return
        end
        if evt.key == :right || (evt.key == :char && evt.char == 'l')
            m.confirm_modal_selected = m.confirm_modal_selected == :cancel ? :confirm : :cancel
            return
        end
        if evt.key == :enter
            if m.confirm_modal_selected == :confirm && confirm_mark_failed_id !== nothing
                handle = _handle_for_experiment(m, confirm_mark_failed_id)
                if handle !== nothing
                    Database.fail_experiment!(handle, confirm_mark_failed_id, "Marked as failed from dashboard")
                end
            end
            m.confirm_mark_failed_id = nothing
            return
        end
        return
    end

    # Global keys (letter keys come as :char with evt.char)
    if evt.key == :char && (evt.char == 'q' || evt.char == 'Q')
        m.quit = true
        return
    end
    if evt.key == :char && evt.char == 'r'
        m._last_poll = 0.0
        m._last_folder_discover = 0.0
        return
    end
    # Tab switching
    max_tab = 2

    if evt.key == :f1 || (evt.key == :char && evt.char == '1')
        m.active_tab = 1
    elseif evt.key == :f2 || (evt.key == :char && evt.char == '2')
        m.active_tab = 2
    elseif evt.key == :left || (evt.key == :char && evt.char == 'h')
        m.active_tab = max(1, m.active_tab - 1)
    elseif evt.key == :right || (evt.key == :char && evt.char == 'l')
        m.active_tab = min(max_tab, m.active_tab + 1)
    end

    # Route to tab-specific handler
    @match m.active_tab begin
        1 => _update_runs_tab!(m, evt)
        2 => _update_running_tab!(m, evt)
        _ => nothing
    end
end
Tachikoma.should_quit(m::ProgressDashboard) = m.quit

# === Runs Tab ===

function _update_runs_tab!(m::ProgressDashboard, evt::KeyEvent)
    isempty(m.admin_experiments) && return

    # [f] mark as failed: open confirmation modal when selection is running
    if evt.key == :char && evt.char == 'f'
        if m.runs_selected >= 1 && m.runs_selected <= length(m.admin_experiments)
            exp = m.admin_experiments[m.runs_selected]
            if exp.status == :running && !isempty(exp.id)
                m.confirm_mark_failed_id = exp.id
                m.confirm_modal_selected = :cancel
            end
        end
        return
    end

    previous_id = m.selected_experiment_id

    if evt.key == :up || evt.key == :ctrl && evt.char == 'k'
        m.runs_selected = max(1, m.runs_selected - 1)
    elseif evt.key == :down || evt.key == :ctrl && evt.char == 'j'
        m.runs_selected = min(length(m.admin_experiments), m.runs_selected + 1)
    elseif m.runs_selected == 0 && !isempty(m.admin_experiments)
        m.runs_selected = 1
    end

    if m.runs_selected > 0 && m.runs_selected <= length(m.admin_experiments)
        exp = m.admin_experiments[m.runs_selected]
        m.selected_experiment_id = exp.id
    else
        m.selected_experiment_id = ""
    end

    if m.selected_experiment_id != previous_id
        m.task_scroll_offset = 0
        m.running_focus = 1
        _refresh_selected_tasks!(m)
    end
end

# === Running Tab ===

function _update_running_tab!(m::ProgressDashboard, evt::KeyEvent)
    if evt.key == :char && evt.char == 'a'
        m.task_list_msg_delta -= 1
        return
    end
    if evt.key == :char && evt.char == 'd'
        m.task_list_msg_delta += 1
        return
    end
    if evt.key == :up || evt.key == :ctrl && evt.char == 'k'
        m.task_scroll_offset = max(0, m.task_scroll_offset - 1)
    elseif evt.key == :down || evt.key == :ctrl && evt.char == 'j'
        m.task_scroll_offset += 1
    end
    return
end
