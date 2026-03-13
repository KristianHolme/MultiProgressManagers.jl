"""
Running experiments tab - shows active experiments with real-time metrics.
"""

function _view_running_tab!(m::ProgressDashboard, area::Rect, buf)
    # Split area: 30% top, 70% bottom
    main_layout = Layout(Vertical, [Percent(30), Fill()])
    main_rows = tsplit(main_layout, area)
    
    # Top section: Table (60%) and Histogram (40%)
    top_layout = Layout(Horizontal, [Percent(60), Fill()])
    top_cols = tsplit(top_layout, main_rows[1])
    
    # Render experiment details
    _view_experiment_detail_panel!(m, top_cols[1], buf)
    
    # Render Histogram
    _view_task_histogram!(m, top_cols[2], buf)
    
    # Bottom section: Task List
    _view_task_list!(m, main_rows[2], buf)
end

function _find_selected_experiment(m::ProgressDashboard)::Union{ExperimentAdminView,Nothing}
    isempty(m.selected_experiment_id) && return nothing
    for exp in m.admin_experiments
        if exp.id == m.selected_experiment_id
            return exp
        end
    end
    return nothing
end

function _render_task_placeholder!(
    area::Rect,
    buf::Buffer;
    title::String = " Tasks ",
    message::String,
)
    block = Block(
        title = title,
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner_area = render(block, area, buf)
    set_string!(
        buf,
        inner_area.x,
        inner_area.y + 1,
        message,
        tstyle(:text_dim);
        max_x = right(inner_area),
    )
    return nothing
end

function _view_experiment_detail_panel!(m::ProgressDashboard, area::Rect, buf)
    border_style = tstyle(:border)
    title_style = tstyle(:title, bold = true)

    table_block = Block(
        title = " Experiment Details ",
        border_style = border_style,
        title_style = title_style
    )
    table_area = render(table_block, area, buf)

    exp = _find_selected_experiment(m)
    if exp === nothing
        set_string!(
            buf,
            table_area.x,
            table_area.y + 1,
            "Select an experiment in Runs tab",
            tstyle(:text_dim);
            max_x = right(table_area)
        )
        return
    end

    name = isempty(exp.name) ? "Unknown" : exp.name
    status = exp.status
    total_tasks = exp.total_tasks
    completed_tasks = exp.completed_tasks
    total_steps = exp.total_steps
    current_step = exp.current_step
    progress_pct = total_tasks > 0 ? (completed_tasks / total_tasks) * 100 : (total_steps > 0 ? (current_step / total_steps) * 100 : 0.0)

    started_at = exp.started_at
    finished_at = exp.finished_at
    duration_str = format_duration(started_at, finished_at)

    y = table_area.y + 1
    x = table_area.x
    max_x = right(table_area)

    status_style = @match status begin
        :running => tstyle(:warning)
        :completed => tstyle(:success)
        :failed => tstyle(:error)
        _ => tstyle(:text)
    end

    # ETA: use task completion rate if available, else step rate
    eta_str = "N/A"
    if status == :completed
        eta_str = "Done"
    elseif status == :running && started_at !== nothing
        elapsed_seconds = time() - Dates.datetime2unix(started_at)
        if total_tasks > 0 && completed_tasks > 0
            avg_time_per_task = elapsed_seconds / completed_tasks
            remaining_tasks = total_tasks - completed_tasks
            eta_seconds = avg_time_per_task * remaining_tasks
            eta_hours = floor(Int, eta_seconds / 3600)
            eta_mins = floor(Int, (eta_seconds % 3600) / 60)
            eta_secs = floor(Int, eta_seconds % 60)
            eta_str = eta_hours > 0 ? @sprintf("%dh %02dm %02ds", eta_hours, eta_mins, eta_secs) : @sprintf("%dm %02ds", eta_mins, eta_secs)
        elseif total_steps > 0 && current_step > 0
            avg_time_per_step = elapsed_seconds / current_step
            remaining_steps = total_steps - current_step
            eta_seconds = avg_time_per_step * remaining_steps
            eta_hours = floor(Int, eta_seconds / 3600)
            eta_mins = floor(Int, (eta_seconds % 3600) / 60)
            eta_secs = floor(Int, eta_seconds % 60)
            eta_str = eta_hours > 0 ? @sprintf("%dh %02dm %02ds", eta_hours, eta_mins, eta_secs) : @sprintf("%dm %02ds", eta_mins, eta_secs)
        end
    end

    started_str = format_datetime_for_started_column(started_at, true)

    set_string!(buf, x, y, name, tstyle(:accent, bold = true); max_x = max_x)
    y += 1
    set_string!(buf, x, y, "Status: $(string(status))", status_style; max_x = max_x)
    y += 1
    set_string!(buf, x, y, "Started: $(started_str)", tstyle(:text_dim); max_x = max_x)
    y += 1
    set_string!(buf, x, y, "Tasks: $(completed_tasks)/$(total_tasks) completed", tstyle(:text); max_x = max_x)
    y += 1
    set_string!(buf, x, y, @sprintf("Completion: %.1f%%", progress_pct), tstyle(:text); max_x = max_x)
    y += 1
    set_string!(buf, x, y, "Duration: $(duration_str)", tstyle(:text_dim); max_x = max_x)
    y += 1
    if status == :running
        set_string!(buf, x, y, "ETA: $(eta_str)", tstyle(:warning); max_x = max_x)
        y += 1
    end
end

# === Pane styling ===

function _pane_border(pane::Int)
    # No focus tracking yet, all use border style
    tstyle(:border)
end

function _pane_title(pane::Int)
    tstyle(:title, bold = true)
end

function _view_task_list!(m::ProgressDashboard, area::Rect, buf::Buffer)
    exp_id = m.selected_experiment_id
    if isempty(exp_id)
        return _render_task_placeholder!(
            area,
            buf;
            message = "Select an experiment to view tasks",
        )
    end

    exp = _find_selected_experiment(m)
    exp_name = exp === nothing ? "Selected Experiment" : (isempty(exp.name) ? "Unknown" : exp.name)

    tasks = m._selected_tasks
    if !m._selected_tasks_loaded
        return _render_task_placeholder!(
            area,
            buf;
            message = "No database selected",
        )
    end
    if isempty(tasks)
        return _render_task_placeholder!(
            area,
            buf;
            message = "No tasks found for this experiment",
        )
    end

    block = Block(
        title = " Tasks for $(exp_name) ",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner_area = render(block, area, buf)

    header_y = inner_area.y
    header_style = tstyle(:text_dim, bold = true)

    col_num = inner_area.x
    col_progress = inner_area.x + 8
    col_speed = inner_area.x + 30
    col_status = inner_area.x + 45
    col_message = inner_area.x + 55
    remaining = right(inner_area) - col_message
    min_msg_width = 5
    min_desc_width = 5
    base_msg_width = div(remaining, 2)
    msg_width = clamp(
        base_msg_width + m.task_list_msg_delta,
        min_msg_width,
        remaining - min_desc_width,
    )
    col_description = col_message + msg_width
    m.task_list_msg_delta = msg_width - base_msg_width

    desc_width = remaining - msg_width
    msg_header = msg_width >= 7 ? "Message" : "Msg"
    desc_header = desc_width >= 11 ? "Description" : "Descr"

    set_string!(buf, col_num, header_y, "Task #", header_style)
    set_string!(buf, col_progress, header_y, "Progress", header_style)
    set_string!(buf, col_speed, header_y, "Speed", header_style)
    set_string!(buf, col_status, header_y, "Status", header_style)
    set_string!(buf, col_message, header_y, msg_header, header_style)
    set_string!(buf, col_description, header_y, desc_header, header_style)
    y = header_y + 1
    max_y = bottom(inner_area)

    num_visible = max_y - y
    if num_visible <= 0
        return
    end

    num_tasks = length(tasks)
    scroll_offset = min(m.task_scroll_offset, max(0, num_tasks - num_visible))
    start_idx = scroll_offset + 1
    end_idx = min(start_idx + num_visible - 1, num_tasks)

    for i in start_idx:end_idx
        task = tasks[i]
        task_num = task.task_number
        total = task.total_steps
        current = task.current_step
        status = task.status
        started_at = task.started_at
        last_updated = task.last_updated
        elapsed = last_updated - started_at
        speed = elapsed > 0 ? current / elapsed : 0.0
        pct = total > 0 ? current / total : 0.0
        style = @match status begin
            :running => tstyle(:warning)
            :completed => tstyle(:success)
            :failed => tstyle(:error)
            _ => tstyle(:text)
        end

        set_string!(buf, col_num, y, @sprintf("#%03d", task_num), style)
        gauge_width = 20
        gauge_area = Rect(col_progress, y, gauge_width, 1)
        gauge = Gauge(pct; label = "")
        render(gauge, gauge_area, buf)
        set_string!(buf, col_speed, y, format_speed(speed), tstyle(:text))
        set_string!(buf, col_status, y, String(status), style)

        msg_str = task.display_message
        msg_style = isempty(msg_str) ? tstyle(:text_dim) : tstyle(:text)
        set_string!(buf, col_message, y, msg_str, msg_style; max_x = col_description - 1)

        desc_str = task.description
        desc_style = isempty(desc_str) ? tstyle(:text_dim) : tstyle(:text)
        set_string!(buf, col_description, y, desc_str, desc_style; max_x = right(inner_area))
        y += 1
    end
end
