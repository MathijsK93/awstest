# == Schema Information
#
# Table name: case_steps
#
#  created_at        :datetime         not null
#  credit_case_id    :integer          indexed
#  creditor_notified :boolean
#  id                :integer          not null, primary key
#  label             :string(255)
#  notified_debtor   :boolean          default(FALSE)
#  performed_at      :datetime
#  price             :decimal(10, 2)
#  scheduled_at      :datetime
#  state             :string(255)      default("unperformed"), indexed
#  updated_at        :datetime         not null
#  workflow_step_id  :integer          indexed
#

require 'holidays'
require 'holidays/nl'

class CaseStep < ActiveRecord::Base
	belongs_to :credit_case, :inverse_of => :steps
	belongs_to :workflow_step
	has_many :actions,  :class_name => "CaseAction",
											:dependent => :destroy,
											:inverse_of => :step,
											:after_add => :reschedule!,
											:after_remove => :reschedule!

	attr_accessible :credit_case_id, :scheduled_at, :type, :workflow_step_id
	attr_accessor :label, :price

	validates :credit_case_id, :presence => true
	validates :state, :inclusion => { :in => ['unperformed', 'performed'] }

	validates_uniqueness_of :workflow_step_id, :scope => :credit_case_id, :allow_nil => true

	scope :unperformed, where(:state => "unperformed")
	scope :performed, where(:state => "performed")
	scope :unnotified, where(:notified_debtor => false)
	scope :perform_now, lambda { |now| perform_within(now) }
	scope :perform_within, lambda { |now| unperformed.where("scheduled_at <= ?", now) }
	scope :perform_today, lambda { |now| unperformed.where(:scheduled_at => now.at_beginning_of_day..now.at_end_of_day) }
	scope :for_open_cases, includes(:credit_case).where(:credit_cases => { :state => :open })

	delegate :name, :after_step, :after_steps_in_days, :needs_notification, :next_steps, :reference, :owner_performable, :to => :workflow_step

	before_validation :check_weekend_and_holidays
	def check_weekend_and_holidays
		while self[:scheduled_at].wday == 6 or self[:scheduled_at].wday == 0 or self[:scheduled_at].to_date.holiday?(:nl)
			self[:scheduled_at] = self[:scheduled_at] + 1.day
		end
	end

	# Performs the step and schedules the next
	def perform
		if !performable?
			self[:scheduled_at] = self[:scheduled_at] + 1.day
			self.save
			return
		end
		if workflow_step.reference == '1'
			credit_case.start_collections_process
			credit_case.update_prices
			credit_case.save
		elsif workflow_step.reference == '6' && (credit_case.autoforward == false || credit_case.bailiff_id.nil?)
			CreditorMailer.case_finished(credit_case).deliver unless creditor_notified?
			self.creditor_notified = true
			self.scheduled_at = scheduled_at + 1.day
			credit_case.finish! unless credit_case.finished?
			self.save!
			return
		end
		results = perform_scheduled_actions(:on => "perform")

		performed! unless results.include?(false)
	end

	# Changes the state to performed
	def performed!
		self[:performed_at] = Time.now
		self[:state] = "performed"
		save!
		schedule_next
		price_to_add = workflow_step.try(:price) || 0.00
		credit_case.billing_price ||= 0.00
		credit_case.billing_price += price_to_add
		credit_case.save
	end

	def performed?
		state == 'performed'
	end

	# Only perform a step when the credit case is not paid or paused
	def performable?
		credit_case.open? || credit_case.finished?
	end

	# Performs the unperformed actions that are associated with this step
	def perform_scheduled_actions(conditions={})
		# Remove actions that can not be performed at this moment, we should never perform them
		actions.unperformed.where(conditions).reject(&:performable?).map(&:destroy)

		# Perform the actions that can be performed
		actions.unperformed.where(conditions).order('type ASC').select(&:performable?).collect(&:perform)
	end

	# Schedules the next step
	def schedule_next
		return if workflow_step.nil? or next_steps.empty?

		# if the step is performed prematurely by admin, do not speed up the rest of the schedule
		now = (scheduled_at and scheduled_at.future?) ? scheduled_at : Time.now

		next_steps.each do |next_step|
			# only schedule steps not already scheduled.
			if credit_case.steps.where(:workflow_step_id => next_step.id.to_s).empty?
				schedule_next_at = now + next_step.after_step_in_days
				@scheduled_step = credit_case.steps.build
				@scheduled_step.workflow_step_id = next_step.id
				@scheduled_step.scheduled_at = schedule_next_at
				@scheduled_step.state = "unperformed"
				@scheduled_step.save!
				@scheduled_step.after_schedule
			end
		end
		credit_case.save
		@scheduled_step
	end

	# Changes the time to execute this step
	def reschedule!(_)
		actions.unperformed.reload
		return if actions.unperformed.empty?
		update_attribute(:scheduled_at, actions.unperformed.sort { |x,y| x.run_at!(scheduled_at) <=> y.run_at!(scheduled_at) }.first.run_at!(scheduled_at))
	end

	def after_schedule
		scheduled
	end

	def scheduled_at=(date)
		self[:scheduled_at] = date.is_a?(Date) ? date.to_time : date
	end

	def scheduled
		workflow_step.actions.each do |action|
			actions << action.clone_to_case_action
		end
	end

	def history_date
		performed_at || scheduled_at
	end
end
