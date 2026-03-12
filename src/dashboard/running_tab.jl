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
        if !ismissing(exp.id) && exp.id == m.selected_experiment_id
            return exp
        end
    end
    return nothing
end

function _view_experiment_detail_panel!(m::ProgressDashboard, area::Rect, buf)
    # Focus indicator
    border_style = m.running_focus == 1 ? tstyle(:accent) : tstyle(:border)
    title_style = m.running_focus == 1 ? tstyle(:accent, bold = true) : tstyle(:title, bold = true)

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

    name = ismissing(exp.name) ? "Unknown" : exp.name
    status = ismissing(exp.status) ? :unknown : exp.status
    total_tasks = ismissing(exp.total_tasks) ? 0 : exp.total_tasks
    completed_tasks = ismissing(exp.completed_tasks) ? 0 : exp.completed_tasks
    total_steps = ismissing(exp.total_steps) ? 0 : exp.total_steps
    current_step = ismissing(exp.current_step) ? 0 : exp.current_step
    progress_pct = total_tasks > 0 ? (completed_tasks / total_tasks) * 100 : (total_steps > 0 ? (current_step / total_steps) * 100 : 0.0)

    started_at = exp.started_at
    finished_at = ismissing(exp.finished_at) ? nothing : exp.finished_at
    duration_str = ismissing(started_at) ? "N/A" : format_duration(started_at, finished_at)

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
    elseif status == :running && !ismissing(started_at)
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

    set_string!(buf, x, y, name, tstyle(:accent, bold = true); max_x = max_x)
    y += 1
    set_string!(buf, x, y, "Status: $(string(status))", status_style; max_x = max_x)
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
    # Focus indicator
    border_style = m.running_focus == 2 ? tstyle(:accent) : tstyle(:border)
    title_style = m.running_focus == 2 ? tstyle(:accent, bold = true) : tstyle(:title, bold = true)
    
    # 1. Get selected experiment ID
    exp_id = m.selected_experiment_id
    if isempty(exp_id)
        block = Block(title = " Tasks ", border_style = border_style, title_style = title_style)
        inner_area = render(block, area, buf)
        set_string!(buf, inner_area.x, inner_area.y + 1, "Select an experiment to view tasks", tstyle(:text_dim))
        return
    end
    
    exp = _find_selected_experiment(m)
    exp_name = exp === nothing ? "Selected Experiment" : (ismissing(exp.name) ? "Unknown" : exp.name)

    handle = _handle_for_experiment(m, exp_id)
    if handle === nothing
        block = Block(title = " Tasks ", border_style = border_style, title_style = title_style)
        inner_area = render(block, area, buf)
        set_string!(buf, inner_area.x, inner_area.y + 1, "No database selected", tstyle(:text_dim))
        return
    end

    # 2. Query tasks
    tasks = Database.get_experiment_tasks(handle, exp_id)
    if isempty(tasks)
        block = Block(title = " Tasks ", border_style = border_style, title_style = title_style)
        inner_area = render(block, area, buf)
        set_string!(buf, inner_area.x, inner_area.y + 1, "No tasks found for this experiment", tstyle(:text_dim))
        return
    end
    
    # 3. Render block
    block = Block(title = " Tasks for $(exp_name) ", border_style = border_style, title_style = title_style)
    inner_area = render(block, area, buf)
    
    # 4. Header
    header_y = inner_area.y
    header_style = tstyle(:text_dim, bold = true)
    
    col_num = inner_area.x
    col_progress = inner_area.x + 8
    col_speed = inner_area.x + 30
    col_status = inner_area.x + 45
    col_message = inner_area.x + 55

    set_string!(buf, col_num, header_y, "Task #", header_style)
    set_string!(buf, col_progress, header_y, "Progress", header_style)
    set_string!(buf, col_speed, header_y, "Speed", header_style)
    set_string!(buf, col_status, header_y, "Status", header_style)
    set_string!(buf, col_message, header_y, "Message", header_style)
    y = header_y + 1
    max_y = bottom(inner_area)
    
    # 5. List items
    num_visible = max_y - y
    if num_visible <= 0
        return
    end
    
    # Clamp scroll offset
    num_tasks = nrow(tasks)
    if m.task_scroll_offset > num_tasks - num_visible
        m.task_scroll_offset = max(0, num_tasks - num_visible)
    end
    
    start_idx = m.task_scroll_offset + 1
    end_idx = min(start_idx + num_visible - 1, num_tasks)
    
    for i in start_idx:end_idx
        row = tasks[i, :]
        task_num = ismissing(row.task_number) ? i : row.task_number
        total = ismissing(row.total_steps) ? 0 : row.total_steps
        current = ismissing(row.current_step) ? 0 : row.current_step
        status = ismissing(row.status) ? "unknown" : row.status
        started_at = ismissing(row.started_at) ? 0.0 : row.started_at
        last_updated = ismissing(row.last_updated) ? 0.0 : row.last_updated
        
        # Speed calculation
        elapsed = last_updated - started_at
        speed = elapsed > 0 ? current / elapsed : 0.0
        # Progress %
        pct = total > 0 ? current / total : 0.0
        # Style
        style = @match Symbol(status) begin
            :running => tstyle(:warning)
            :completed => tstyle(:success)
            :failed => tstyle(:error)
            _ => tstyle(:text)
        end
        # Render row
        set_string!(buf, col_num, y, @sprintf("#%03d", task_num), style)
        # Progress bar (gauge)
        gauge_width = 20
        gauge_area = Rect(col_progress, y, gauge_width, 1)
        gauge = Gauge(pct; label = "")
        render(gauge, gauge_area, buf)
        set_string!(buf, col_speed, y, format_speed(speed), tstyle(:text))
        set_string!(buf, col_status, y, status, style)
        # Display message (epochs, stage, etc.)
        msg = hasproperty(row, :display_message) ? row[:display_message] : missing
        msg_str = (msg === missing || ismissing(msg) || isempty(string(msg))) ? "" : string(msg)
        msg_style = isempty(msg_str) ? tstyle(:text_dim) : tstyle(:text)
        set_string!(buf, col_message, y, msg_str, msg_style; max_x = right(inner_area))
        y += 1
    end
end
