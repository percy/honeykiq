require 'sidekiq/api'

module Honeykiq
  class ServerMiddleware
    def initialize(libhoney: nil, honey_client: nil)
      @libhoney = libhoney || honey_client
    end

    def call(_worker, msg, queue_name)
      job = Sidekiq::Job.new(msg, queue_name)
      queue = Sidekiq::Queue.new(queue_name)

      start_span(name: job.display_class, serialized_trace: msg['serialized_trace']) do |event|
        call_with_event(event, job, queue) { yield }
      end
    end

    def extra_fields
      {}
    end

    private

    attr_reader :libhoney

    def libhoney?
      !!libhoney
    end

    def start_span(name:, serialized_trace:)
      if libhoney?
        libhoney.event.tap do |event|
          duration_ms(event) { yield event }
        ensure
          event.send
        end
      else
        Honeycomb.start_span(name: name, serialized_trace: serialized_trace) { |event| yield event }
      end
    end

    def call_with_event(event, job, queue)
      event.add(default_fields(job, queue))
      yield
      event.add_field(:'job.status', 'finished')
    rescue StandardError => error
      on_error(event, error)
      raise
    ensure
      event.add(extra_fields)
    end

    def default_fields(job, queue)
      {
        type: :job,
        **job_fields(job),
        **queue_fields(queue),
        'meta.thread_id': Thread.current.object_id
      }
    end

    def job_fields(job)
      {
        'job.class': job.display_class,
        'job.attempt_number': (job['retry_count'].to_i.nonzero? || 0) + 1,
        'job.id': job.jid,
        'job.arguments_bytes': job.args.to_json.bytesize,
        'job.latency_sec': job.latency,
        'job.batch_id': job['bid']
      }.compact
    end

    def queue_fields(queue)
      {
        'queue.name': queue.name,
        'queue.size': queue.size
      }
    end

    def duration_ms(event)
      start_time = Time.now
      yield
    ensure
      duration = Time.now - start_time
      event.add_field(:duration_ms, duration * 1000)
    end

    def on_error(event, error)
      return unless event

      event.add_field(:'job.status', 'failed')
      return unless libhoney?

      event.add(
        'error.class': error.class.name,
        'error.message': error.message
      )
    end
  end
end
