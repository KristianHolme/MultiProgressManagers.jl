"""
Runs list tab - shows all experiments from the database.
"""

"""Truncate `s` to at most `max_chars` display characters; append `...` when shortened (UTF-8 safe)."""
function _truncate_display(s::String, max_chars::Int)::String
    max_chars < 1 && return ""
    if length(s) <= max_chars
        return s
    end
    if max_chars <= 3
        return String(collect(s)[1:max_chars])
    end
    head = max_chars - 3
    chars = collect(s)
    return String(chars[1:head]) * "..."
end

function _view_runs_tab!(m::ProgressDashboard, area::Rect, buf::Buffer)
    # Render outer block
    outer = Block(
        title = " All Experiments ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    inner = render(outer, area, buf)
    
    # Use admin_experiments from model (refreshed by _poll_database!)
    experiments = m.admin_experiments
    
    if isempty(experiments)
        set_string!(buf, inner.x, inner.y + 1, "No experiments found", tstyle(:text_dim); max_x = right(inner))
        return
    end
    
    # Header for the list
    header_y = inner.y
    header_style = tstyle(:text_dim, bold = true)

    # If oldest experiment was not started today (local calendar), show date in Started column
    today_local = Dates.today()
    started_dates = Dates.Date[]
    for exp in experiments
        sa = exp.started_at
        sa === nothing && continue
        push!(started_dates, Dates.Date(instant_to_local_wall_datetime(sa)))
    end
    show_date = !isempty(started_dates) && minimum(started_dates) < today_local
    time_col_width = show_date ? 16 : 10

    # Minimum widths for Status / Completed / Duration (may shrink if the terminal is narrow)
    min_status_w = 8
    min_progress_w = 10
    min_duration_w = 8

    # Sample rows to size tail columns (cap work for huge lists)
    sample_n = min(length(experiments), 64)
    max_status_w = min_status_w
    max_progress_w = min_progress_w
    max_duration_w = min_duration_w
    max_name_len = 0
    for i in 1:sample_n
        exp = experiments[i]
        nm = isempty(exp.name) ? "Unknown" : exp.name
        max_name_len = max(max_name_len, length(nm))
        status = String(exp.status)
        total_tasks = exp.total_tasks
        completed_tasks = exp.completed_tasks
        progress_pct = total_tasks > 0 ? (completed_tasks / total_tasks) * 100 : 0.0
        started_at = exp.started_at
        finished_at = exp.finished_at
        progress_str = @sprintf("%d/%d (%.0f%%)", completed_tasks, total_tasks, progress_pct)
        duration_str = format_duration(started_at, finished_at)
        max_status_w = max(max_status_w, length(status))
        max_progress_w = max(max_progress_w, length(progress_str))
        max_duration_w = max(max_duration_w, length(duration_str))
    end
    # Longest name may occur outside the sample; one cheap pass over names only
    for exp in experiments
        nm = isempty(exp.name) ? "Unknown" : exp.name
        max_name_len = max(max_name_len, length(nm))
    end

    avail = inner.width
    min_name_w = 4

    status_w = max(min_status_w, max_status_w)
    progress_w = max(min_progress_w, max_progress_w)
    duration_w = max(min_duration_w, max_duration_w)

    function _runs_row_width(nw::Int, sw::Int, pw::Int, dw::Int)::Int
        return time_col_width + 1 + nw + 1 + sw + 1 + pw + 1 + dw
    end

    # Pack columns to the left: name width fits content (capped by space), extra room stays empty on the right
    function _nw_max(sw::Int, pw::Int, dw::Int)::Int
        return avail - _runs_row_width(0, sw, pw, dw)
    end

    name_w = _nw_max(status_w, progress_w, duration_w)
    deficit = min_name_w - name_w
    if deficit > 0
        take = min(deficit, duration_w - min_duration_w)
        duration_w -= take
        deficit -= take
    end
    if deficit > 0
        take = min(deficit, progress_w - min_progress_w)
        progress_w -= take
        deficit -= take
    end
    if deficit > 0
        take = min(deficit, status_w - min_status_w)
        status_w -= take
        deficit -= take
    end
    name_w = _nw_max(status_w, progress_w, duration_w)
    while name_w < 1
        shrunk = false
        if duration_w > 1
            duration_w -= 1
            shrunk = true
        elseif progress_w > 1
            progress_w -= 1
            shrunk = true
        elseif status_w > 1
            status_w -= 1
            shrunk = true
        end
        if !shrunk
            break
        end
        name_w = _nw_max(status_w, progress_w, duration_w)
    end
    name_w = min(max(min_name_w, max_name_len), max(1, name_w))

    col_time = inner.x
    col_name = col_time + time_col_width + 1
    col_status = col_name + name_w + 1
    col_progress = col_status + status_w + 1
    col_duration = col_progress + progress_w + 1

    set_string!(buf, col_time, header_y, "Started", header_style)
    set_string!(buf, col_name, header_y, "Name", header_style)
    set_string!(buf, col_status, header_y, "Status", header_style)
    set_string!(buf, col_progress, header_y, "Completed", header_style)
    set_string!(buf, col_duration, header_y, "Duration", header_style)

    # Prepare items for SelectableList
    items = map(experiments) do exp
        name = isempty(exp.name) ? "Unknown" : exp.name
        status = String(exp.status)
        total_tasks = exp.total_tasks
        completed_tasks = exp.completed_tasks
        progress_pct = total_tasks > 0 ? (completed_tasks / total_tasks) * 100 : 0.0
        started_at = exp.started_at
        finished_at = exp.finished_at
        duration_str = format_duration(started_at, finished_at)
        start_time_str = format_datetime_for_started_column(started_at, show_date)
        progress_str = @sprintf("%d/%d (%.0f%%)", completed_tasks, total_tasks, progress_pct)
        name_disp = _truncate_display(name, name_w)
        status_disp = _truncate_display(status, status_w)
        progress_disp = _truncate_display(progress_str, progress_w)
        duration_disp = _truncate_display(duration_str, duration_w)
        label = @sprintf(
            "%-*s %-*s %-*s %-*s %-*s",
            time_col_width,
            start_time_str,
            name_w,
            name_disp,
            status_w,
            status_disp,
            progress_w,
            progress_disp,
            duration_w,
            duration_disp,
        )

        style = @match Symbol(status) begin
            :running => tstyle(:warning)
            :completed => tstyle(:success)
            :failed => tstyle(:error)
            _ => tstyle(:text)
        end

        return ListItem(label, style)
    end
    
    # Render SelectableList
    list = SelectableList(items; selected = m.runs_selected)
    list_area = Rect(inner.x, inner.y + 1, inner.width, inner.height - 1)
    render(list, list_area, buf)
end

function _view_task_histogram!(m::ProgressDashboard, area::Rect, buf::Buffer)
    exp_id = m.selected_experiment_id
    if isempty(exp_id) && m.runs_selected > 0 && m.runs_selected <= length(m.admin_experiments)
        exp = m.admin_experiments[m.runs_selected]
        exp_id = exp.id
    end
    
    if isempty(exp_id)
        return
    end

    exp = _find_selected_experiment(m)
    if exp === nothing
        return
    end

    tasks = m._selected_tasks
    if !m._selected_tasks_loaded
        return
    end

    bins = zeros(Int, 11)
    if !isempty(tasks)
        for task in tasks
            total = task.total_steps
            current = task.current_step
            pct = total > 0 ? current / total : 0.0
            bin_idx = pct >= 1.0 ? 11 : (floor(Int, pct * 10) + 1)
            bins[bin_idx] += 1
        end
    end

    if maximum(bins) == 0
        status = String(exp.status)
        total_tasks = exp.total_tasks
        if (status == "completed" || status == "failed") && total_tasks > 0
            bins[11] = total_tasks
        else
            return
        end
    end

    labels = ["[0,10)%", "[10,20)%", "[20,30)%", "[30,40)%", "[40,50)%", "[50,60)%", "[60,70)%", "[70,80)%", "[80,90)%", "[90,100)%", "100%"]
    entries = [BarEntry(labels[i], bins[i]) for i in 1:11]
    max_count = maximum(bins)
    chart = BarChart(entries; max_val = (max_count > 0 ? max_count : 1))
    block = Block(title = " Task Completion Distribution ", border_style = tstyle(:border))
    inner_area = render(block, area, buf)
    render(chart, inner_area, buf)
    return
end
