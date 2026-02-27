// Timeline component - renders iteration cards with collapsible detail

const Timeline = {
  mermaidSequence: 0,

  render(session) {
    const container = document.getElementById('timeline');
    container.textContent = '';

    const iterations = session.iterations || [];
    const totalSteps = iterations.length;

    iterations.forEach((it, index) => {
      const d = it.data || it;
      const isSubmit = d.action === 'final' || d.action === 'forced_final';
      const isUserPrompt = d.action === 'user_prompt';
      const isError = !isSubmit && !isUserPrompt && d.execution && !d.execution.ok;
      const isLast = index === iterations.length - 1;
      const expanded = isLast || isError || isUserPrompt;

      const card = this.buildCard(d, isSubmit, isError, expanded, totalSteps, index + 1);
      card.style.setProperty('--i', index);
      card.classList.add('animate-in');
      container.appendChild(card);
    });

    if (typeof Prism !== 'undefined') Prism.highlightAll();
  },

  _makeLabel(iconClass, text) {
    const label = document.createElement('div');
    label.className = 'timeline-card__section-label';
    const icon = document.createElement('i');
    icon.className = iconClass;
    label.appendChild(icon);
    label.appendChild(document.createTextNode(' ' + text));
    return label;
  },

  buildCard(d, isSubmit, isError, expanded, totalSteps, displayIndex = d.iteration) {
    const isUserPrompt = d.action === 'user_prompt';

    const card = document.createElement('div');
    card.id = 'step-' + displayIndex;
    card.className = 'timeline-card';
    if (isError) card.classList.add('timeline-card--error');
    if (isUserPrompt) card.classList.add('timeline-card--user');
    if (expanded) card.classList.add('timeline-card--expanded');

    const header = document.createElement('div');
    header.className = 'timeline-card__header';
    header.addEventListener('click', () => card.classList.toggle('timeline-card--expanded'));

    const stepBadge = document.createElement('span');
    stepBadge.className = 'timeline-card__step-badge';
    stepBadge.textContent = displayIndex + '/' + totalSteps;
    header.appendChild(stepBadge);

    const typeBadge = document.createElement('span');
    typeBadge.className = 'timeline-card__type-badge';
    if (isSubmit) {
      typeBadge.classList.add('timeline-card__type-badge--final');
      typeBadge.textContent = 'FINAL';
    } else if (isUserPrompt) {
      typeBadge.classList.add('timeline-card__type-badge--user');
      typeBadge.textContent = 'USER';
    } else {
      typeBadge.classList.add('timeline-card__type-badge--exec');
      typeBadge.textContent = 'EXEC';
    }
    header.appendChild(typeBadge);

    const preview = document.createElement('span');
    preview.className = 'timeline-card__preview';
    if (isSubmit) {
      preview.textContent = truncate(d.answer || '', 50);
    } else if (isUserPrompt) {
      preview.textContent = truncate(d.prompt || '', 50);
    } else {
      preview.textContent = truncate((d.code || '').replace(/\n/g, ' '), 50);
    }
    header.appendChild(preview);

    if (d.latency_s) {
      const latency = document.createElement('span');
      latency.className = 'timeline-card__latency';
      latency.textContent = formatDuration(d.latency_s);
      header.appendChild(latency);
    }

    const chevron = document.createElement('i');
    chevron.className = 'fa-solid fa-chevron-right timeline-card__chevron';
    header.appendChild(chevron);

    card.appendChild(header);

    const body = document.createElement('div');
    body.className = 'timeline-card__body';
    const content = document.createElement('div');
    content.className = 'timeline-card__content';

    if (isSubmit) {
      content.appendChild(this.buildFinalAnswer(d));
    } else if (isUserPrompt) {
      content.appendChild(this.buildUserPrompt(d));
    } else {
      content.appendChild(this.buildCodeSection(d));
      content.appendChild(this.buildExecOutput(d));
    }

    body.appendChild(content);
    card.appendChild(body);
    return card;
  },

  buildUserPrompt(d) {
    const section = document.createElement('div');
    section.appendChild(this._makeLabel('fa-regular fa-comment-dots', 'Follow-up Request'));

    const text = document.createElement('div');
    text.className = 'user-prompt-text';
    text.textContent = d.prompt || '';
    section.appendChild(text);

    return section;
  },

  buildCodeSection(d) {
    const section = document.createElement('div');
    section.appendChild(this._makeLabel('fa-solid fa-code', 'Ruby Code'));

    const codeBlock = document.createElement('div');
    codeBlock.className = 'code-block';

    const copyBtn = document.createElement('button');
    copyBtn.className = 'code-block__copy';
    copyBtn.textContent = 'Copy';
    copyBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      navigator.clipboard.writeText(d.code || '').then(() => {
        copyBtn.textContent = 'Copied!';
        setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1500);
      });
    });
    codeBlock.appendChild(copyBtn);

    const pre = document.createElement('pre');
    pre.className = 'line-numbers';
    const code = document.createElement('code');
    code.className = 'language-ruby';
    code.textContent = d.code || '';
    pre.appendChild(code);
    codeBlock.appendChild(pre);
    section.appendChild(codeBlock);
    return section;
  },

  buildExecOutput(d) {
    const section = document.createElement('div');
    section.appendChild(this._makeLabel('fa-solid fa-terminal', 'Execution Output'));

    const exec = d.execution;
    const output = document.createElement('div');
    output.className = 'exec-output';

    if (!exec) {
      const msg = document.createElement('div');
      msg.className = 'exec-output__message exec-output__message--empty';
      msg.textContent = 'No execution data';
      output.appendChild(msg);
    } else if (!exec.ok) {
      output.classList.add('exec-output--error');
      if (exec.error_class) {
        const cls = document.createElement('div');
        cls.className = 'exec-output__class';
        cls.textContent = exec.error_class;
        output.appendChild(cls);
      }
      const msg = document.createElement('div');
      msg.className = 'exec-output__message exec-output__message--error';
      msg.textContent = exec.error_message || 'Unknown error';
      output.appendChild(msg);
    } else {
      if (exec.stdout) {
        const msg = document.createElement('div');
        msg.className = 'exec-output__message exec-output__message--stdout';
        msg.textContent = exec.stdout;
        output.appendChild(msg);
      }
      if (exec.value_preview) {
        const msg = document.createElement('div');
        msg.className = 'exec-output__message exec-output__message--value';
        msg.textContent = '=> ' + exec.value_preview;
        output.appendChild(msg);
      }
      if (!exec.stdout && !exec.value_preview) {
        const msg = document.createElement('div');
        msg.className = 'exec-output__message exec-output__message--empty';
        msg.textContent = 'No output';
        output.appendChild(msg);
      }
    }

    section.appendChild(output);
    return section;
  },

  buildFinalAnswer(d) {
    const section = document.createElement('div');
    section.appendChild(this._makeLabel('fa-solid fa-flag-checkered', 'Answer'));

    const answer = document.createElement('div');
    answer.className = 'final-answer';
    const text = document.createElement('div');
    text.className = 'final-answer__text';
    const raw = d.answer || '';
    if (typeof marked !== 'undefined' && /[#*_`\-\[]/.test(raw)) {
      text.innerHTML = marked.parse(raw);
      this.renderMermaidBlocks(text);
    } else {
      text.textContent = raw;
    }
    answer.appendChild(text);
    section.appendChild(answer);
    return section;
  },

  renderMermaidBlocks(container) {
    if (typeof DiagramRenderer === 'undefined') return;

    const blocks = container.querySelectorAll('pre > code.language-mermaid');
    blocks.forEach((codeEl) => {
      const pre = codeEl.parentElement;
      if (!pre || !pre.parentElement) return;

      const definition = (codeEl.textContent || '').trim();
      if (!definition) return;

      this.mermaidSequence += 1;
      const host = document.createElement('div');
      host.className = 'mermaid-container final-answer__mermaid';
      host.id = 'final-answer-mermaid-' + this.mermaidSequence;
      pre.replaceWith(host);

      DiagramRenderer.render(host.id, definition);
    });
  },

  buildStreamingCard() {
    const card = document.createElement('div');
    card.className = 'timeline-card streaming-card';

    const header = document.createElement('div');
    header.className = 'timeline-card__header';

    const badge = document.createElement('span');
    badge.className = 'timeline-card__type-badge timeline-card__type-badge--exec streaming-card__badge';
    badge.textContent = 'THINKING';
    header.appendChild(badge);

    const dots = document.createElement('span');
    dots.className = 'streaming-card__dots';
    dots.innerHTML = '<span></span><span></span><span></span>';
    header.appendChild(dots);

    card.appendChild(header);

    const body = document.createElement('div');
    body.className = 'timeline-card__body';
    body.style.maxHeight = '2000px';
    const content = document.createElement('div');
    content.className = 'timeline-card__content';
    const textEl = document.createElement('pre');
    textEl.className = 'streaming-card__text';
    content.appendChild(textEl);
    body.appendChild(content);
    card.appendChild(body);

    return card;
  }
};
