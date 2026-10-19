// Interactive JavaScript for ToDoz Landing Page

document.addEventListener('DOMContentLoaded', () => {
  // Tab switching for interactive showcase
  const tabButtons = document.querySelectorAll('.tab-btn');
  const tabPanes = document.querySelectorAll('.tab-pane');

  tabButtons.forEach(button => {
    button.addEventListener('click', () => {
      const targetTab = button.getAttribute('data-tab');

      tabButtons.forEach(btn => btn.classList.remove('active'));
      tabPanes.forEach(pane => pane.classList.remove('active'));

      button.classList.add('active');
      const activePane = document.getElementById(targetTab);
      if (activePane) {
        activePane.classList.add('active');
      }
    });
  });

  // Simulated Quick Add interactive typing on Hero
  const quickAddText = document.getElementById('quickadd-text');
  if (quickAddText) {
    const examples = [
      'Review PhD thesis draft tomorrow at 4pm p1 #research {nov 30}',
      'Submit AIIC budget every! 2 months !3 days before #finance',
      'Department Bologna meeting every 1st wed at 10am %important',
      'Deploy ToDoz sync engine updates today p1 #dev /sprint-2'
    ];
    let exampleIndex = 0;
    let charIndex = 0;
    let isDeleting = false;

    function typeEffect() {
      const current = examples[exampleIndex];
      if (isDeleting) {
        quickAddText.textContent = current.substring(0, charIndex - 1);
        charIndex--;
      } else {
        quickAddText.textContent = current.substring(0, charIndex + 1);
        charIndex++;
      }

      let speed = isDeleting ? 30 : 60;

      if (!isDeleting && charIndex === current.length) {
        speed = 3000;
        isDeleting = true;
      } else if (isDeleting && charIndex === 0) {
        isDeleting = false;
        exampleIndex = (exampleIndex + 1) % examples.length;
        speed = 500;
      }

      setTimeout(typeEffect, speed);
    }

    setTimeout(typeEffect, 1200);
  }
});
