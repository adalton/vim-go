" don't spam the user when Vim is started in Vi compatibility mode
let s:cpo_save = &cpo
set cpo&vim

" new creates a new terminal with the given command. Mode is set based on the
" global variable g:go_term_mode, which is by default set to :vsplit
function! go#term#new(bang, cmd, errorformat) abort
  return go#term#newmode(a:bang, a:cmd, a:errorformat, go#config#TermMode())
endfunction

" go#term#newmode creates a new terminal with the given command and window mode.
function! go#term#newmode(bang, cmd, errorformat, mode) abort
  let l:mode = a:mode
  if empty(l:mode)
    let l:mode = go#config#TermMode()
  endif

  let l:state = {
        \ 'cmd': a:cmd,
        \ 'bang' : a:bang,
        \ 'winid': win_getid(winnr()),
        \ 'stdout': [],
        \ 'stdout_buf': '',
        \ 'errorformat': a:errorformat,
      \ }

  " execute go build in the files directory
  let l:cd = exists('*haslocaldir') && haslocaldir() ? 'lcd ' : 'cd '
  let l:dir = getcwd()

  execute l:cd . fnameescape(expand("%:p:h"))

  let l:height = go#config#TermHeight()
  let l:width = go#config#TermWidth()

  " setup job for nvim
  if has('nvim')
    execute l:mode . ' __go_term__'
    setlocal filetype=goterm
    setlocal bufhidden=delete
    setlocal winfixheight
    setlocal noswapfile
    setlocal nobuflisted

    " explicitly bind callbacks to state so that within them, self will always
    " refer to state. See :help Partial for more information.
    "
    " Don't set an on_stderr, because it will be passed the same data as
    " on_stdout. See https://github.com/neovim/neovim/issues/2836
    let l:job = {
          \ 'on_stdout': function('s:on_stdout', [], state),
          \ 'on_exit' : function('s:on_exit', [], state),
        \ }
    let l:state.id = termopen(a:cmd, l:job)
    let l:state.termwinid = win_getid(winnr())
    execute l:cd . fnameescape(l:dir)

    " Adjust the window width or height depending on whether it's a vertical or
    " horizontal split.
    if l:mode =~ "vertical" || l:mode =~ "vsplit" || l:mode =~ "vnew"
      exe 'vertical resize ' . l:width
    elseif mode =~ "split" || mode =~ "new"
      exe 'resize ' . l:height
    endif
    " we also need to resize the pty, so there you go...
    call jobresize(l:state.id, l:width, l:height)

  " setup term for vim8
  elseif has('terminal')
    let l:term = {
          \ 'term_rows' : l:height,
          \ 'term_cols' : l:width,
          \ 'out_cb': function('s:out_cb', [], state),
          \ 'exit_cb' : function('s:exit_cb', [], state),
        \ }

    if l:mode =~ "vertical" || l:mode =~ "vsplit" || l:mode =~ "vnew"
          let l:term["vertical"] = l:mode
    endif

    let l:id = term_start(a:cmd, l:term)
    let l:state.id = l:id
    let l:state.termwinid = win_getid(bufwinnr(l:id))
    execute l:cd . fnameescape(l:dir)
  endif

  call win_gotoid(l:state.winid)
  return l:state.id
endfunction

" out_cb continually concat's the self.stdout_buf on recv of stdout
" and sets self.stdout to the new-lined split content in self.stdout_buf
func! s:out_cb(channel, msg) dict abort
  let self.stdout_buf = self.stdout_buf . a:msg
  let self.stdout = split(self.stdout_buf, '\n')
endfunction

function! s:on_stdout(job_id, data, event) dict abort
  " A single empty string means EOF was reached. The first item will never be
  " the empty string except for when it's the only item and is signaling that
  " EOF was reached.
  if len(a:data) == 1 && a:data[0] == ''
    " when there's nothing buffered, return early so that an
    " erroneous message will not be added.
    if self.stdout_buf == ''
      return
    endif

    let self.stdout = add(self.stdout, self.stdout_buf)
  else
    let l:data = copy(a:data)
    let l:data[0] = self.stdout_buf . l:data[0]

    " The last element may be a partial line; save it for next time.
    let self.stdout_buf = l:data[-1]
    let self.stdout = extend(self.stdout, l:data[:-2])
  endif
endfunction

" vim8 exit callback
function! s:exit_cb(job_id, exit_status) dict abort
  call s:handle_exit(a:job_id, a:exit_status, self)
endfunction

" nvim exit callback
function! s:on_exit(job_id, exit_status, event) dict abort
  call s:handle_exit(a:job_id, a:exit_status, self)
endfunction

" handle_exit implements both vim8 and nvim exit callbacks
func s:handle_exit(job_id, exit_status, state) abort
  let l:winid = win_getid(winnr())

  " change to directory where test were run. if we do not do this
  " the quickfix items will have the incorrect paths. 
  " see: https://github.com/fatih/vim-go/issues/2400
  let l:cd = exists('*haslocaldir') && haslocaldir() ? 'lcd ' : 'cd '
  let l:dir = getcwd()
  execute l:cd . fnameescape(expand("%:p:h"))

  let l:listtype = go#list#Type("_term")

  if a:exit_status == 0
    call go#list#Clean(l:listtype)
    execute l:cd l:dir
    if go#config#TermCloseOnExit()
      call win_gotoid(a:state.termwinid)
      close!
    endif
    call win_gotoid(l:winid)
    return
  endif

  let l:title = a:state.cmd
  if type(l:title) == v:t_list
    let l:title = join(a:state.cmd)
  endif

  let l:i = 0
  while l:i < len(a:state.stdout)
    let a:state.stdout[l:i] = substitute(a:state.stdout[l:i], "\r$", '', 'g')
    let l:i += 1
  endwhile

  call go#list#ParseFormat(l:listtype, a:state.errorformat, a:state.stdout, l:title)
  let l:errors = go#list#Get(l:listtype)
  call go#list#Window(l:listtype, len(l:errors))

  " close terminal; we don't need it anymore
  if go#config#TermCloseOnExit()
    call win_gotoid(a:state.termwinid)
    close!
  endif

  if empty(l:errors)
    call go#util#EchoError( '[' . l:title . '] ' . "FAIL")
    execute l:cd l:dir
    call win_gotoid(l:winid)
    return
  endif

  if a:state.bang
    execute l:cd l:dir
    call win_gotoid(l:winid)
    return
  endif

  call win_gotoid(a:state.winid)
  call go#list#JumpToFirst(l:listtype)

  " change back to original working directory 
  execute l:cd l:dir
endfunction

function! go#term#ToggleCloseOnExit() abort
  if go#config#TermCloseOnExit()
    call go#config#SetTermCloseOnExit(0)
    call go#util#EchoProgress("term close on exit disabled")
    return
  endif

  call go#config#SetTermCloseOnExit(1)
  call go#util#EchoProgress("term close on exit enabled")
  return
endfunction

" restore Vi compatibility settings
let &cpo = s:cpo_save
unlet s:cpo_save

" vim: sw=2 ts=2 et
