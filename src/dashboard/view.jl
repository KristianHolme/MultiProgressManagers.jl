"""
Main view function for the Tachikoma dashboard.
"""
function Tachikoma.view(m::ProgressDashboard, f::Frame)
    m.tick += 1
    
    # Poll database for updates
    _poll_database!(m)
    
    buf = f.buffer
    area = f.area
    
    # Outer frame
    outer = Block(
        title = " MultiProgressManagers ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    main = render(outer, area, buf)
    main.width < 4 && return
    
    # Split into: tab bar | content | status bar
    rows = tsplit(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), main)
    length(rows) < 3 && return
    
    tab_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]
    
    # Tab bar
    _render_tab_bar!(m, tab_area, buf)
    
    # Content by tab
    @match m.active_tab begin
        1 => _view_runs_tab!(m, content_area, buf)
        2 => _view_running_tab!(m, content_area, buf)
        _ => nothing
    end

    # Mark-as-failed confirmation modal overlay
    if m.confirm_mark_failed_id !== nothing
        modal = Modal(
            title = "Mark as failed?",
            message = "This experiment is shown as running. Mark it as failed?\n(Useful if the run actually failed but was not updated.)",
            confirm_label = "Mark failed",
            cancel_label = "Cancel",
            selected = m.confirm_modal_selected,
            tick = m.tick
        )
        render(modal, content_area, buf)
    end

    # Status bar
    _render_status_bar!(m, status_area, buf)
end

#TJ|
function _render_tab_bar!(m::ProgressDashboard, area::Rect, buf)
    # Build tab labels
    labels = [
        [Span("1", tstyle(:accent)), Span(" Runs", tstyle(:text))],
        [Span("2", tstyle(:accent)), Span(" Details", tstyle(:text))],
    ]
    active_idx = clamp(m.active_tab, 1, 2)
    
    render(TabBar(labels; active = active_idx), area, buf)
end

function _render_status_bar!(m::ProgressDashboard, area::Rect, buf)
    # Build status info
    si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
    
    # Connection info
    db_name = !isempty(m.db_path) ? basename(m.db_path) : "None"
    
    # Running count
    running_count = count(e -> e.status == :running, m.running_experiments)
    
    left = [
        Span(" $(SPINNER_BRAILLE[si]) ", tstyle(:accent)),
        Span("DB: ", tstyle(:text_dim)),
        Span(db_name, tstyle(:primary)),
        Span("  $(DOT)  ", tstyle(:border)),
        Span("$(running_count) running", tstyle(:success)),
        Span("  $(DOT)  ", tstyle(:border)),
        Span("poll: $(m.poll_frequency_ms)ms", tstyle(:text_dim)),
    ]
    
    right_parts = ["[1-2] tabs  [Tab] focus  [q]uit  [r]efresh  [↑↓]nav"]
    if m.active_tab == 1 && m.confirm_mark_failed_id === nothing
        push!(right_parts, "  [f] mark failed")
    end
    right = [
        Span(join(right_parts), tstyle(:text_dim))
    ]
    
    render(StatusBar(left = left, right = right), area, buf)
end

